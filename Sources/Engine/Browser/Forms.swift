import Foundation

/// A control found on the page, with how to operate it.
public struct FormField: Sendable {
    public enum Kind: String, Sendable { case text, select, radio, checkbox, checkboxGroup = "checkbox_group", combobox, buttons, file }

    public var spec: FieldSpec
    public var kind: Kind
    public var name = ""
    public var htmlID = ""
    public var isInput = false
    public var autocomplete = ""
    /// A search-as-you-type box with too many options to list: type the answer and take the best suggestion.
    public var typeahead = false

    public var id: String { spec.id }
    var selector: String { #"[data-auto-id="\#(spec.id)"]"# }
    func optionSelector(_ i: Int) -> String { #"[data-auto-id="\#(spec.id)"][data-auto-opt="\#(i)"]"# }
    var describe: String { "\"\(spec.label)\" (\(spec.type.rawValue))" }

    /// A box for a one-time code a site emailed (read from the inbox, never asked of the person).
    var isEmailCode: Bool {
        guard kind == .text else { return false }
        let hay = norm("\(spec.label) \(spec.placeholder) \(name)")
        // Some sites mark ordinary questions "one-time-code" so browsers don't fill them in (Eightfold's "Preferred
        // Name"): the mark counts on a box without a label, or one whose label is about a code.
        if autocomplete.lowercased() == "one-time-code" {
            let label = norm("\(spec.label) \(spec.placeholder)").trimmed
            if label.isEmpty || Regex(#"\b(code|pin|otp|passcode|verification|verify)\b"#).matches(label) { return true }
        }
        if Regex(#"zip|postal|area code|country code|promo|referral|discount|coupon|employee|source code|invitation|gift|tax"#).matches(hay) { return false }
        return Regex(#"verification code|verify code|security code|one[- ]?time (pass)?code|passcode|\botp\b|confirmation code|access code|"#
                     + #"\d[- ]digit code|digit code|enter (the |your )?code|code (we )?sent|e-?mail(ed)? code|^code$|pin code|\bverification\b"#).matches(hay)
    }

    /// "resume", "cover_letter" or nil, from the label, name and id.
    var fileKind: String? {
        let hay = "\(spec.label) \(name) \(htmlID)".lowercased()
        if Regex(#"cover[\s_-]*letter"#).matches(hay) { return "cover_letter" }
        if Regex(#"resume|résumé|\bcv\b|curriculum"#).matches(hay) { return "resume" }
        return nil
    }
}

extension WebAgent {
    /// Waits while the page works on something it was just given (Paylocity reads an uploaded resume and, about three
    /// seconds later, fills the form from it, swapping the US address boxes for others when it reads "Peru"): until no
    /// spinner shows and the boxes' values have held still for `quiet` seconds, at most `timeout`. True when the
    /// values changed meanwhile.
    @discardableResult
    public func waitForFormToSettle(root: String? = nil, quiet: TimeInterval = 1.5, timeout: TimeInterval = 12) async -> Bool {
        let script = """
        const r = (root && document.querySelector(root)) || document;
        const values = [...r.querySelectorAll('input, select, textarea')]
          .filter(e => e.type !== 'hidden' && (e.offsetParent || e.getClientRects().length))
          .map(e => (e.name || e.id || e.type) + '=' + (e.type === 'checkbox' || e.type === 'radio' ? e.checked : e.type === 'file' ? '' : e.value));
        const busy = [...r.querySelectorAll('[aria-busy="true"], [role="progressbar"], .spinner, .loading, [class*="spinner" i], [class*="loader" i]')]
          .filter(e => e.offsetParent || e.getClientRects().length).length;
        return { values: values.join('\\n'), busy: busy };
        """
        let start = Date()
        var first: String?
        var last = "", since = Date()
        while Date().timeIntervalSince(start) < timeout {
            let r = (try? await js(script, ["root": root ?? ""])) as? [String: Any] ?? [:]
            let values = r["values"] as? String ?? "", busy = (r["busy"] as? NSNumber)?.intValue ?? 0
            if first == nil { first = values }
            if values != last || busy > 0 { last = values; since = Date() }
            if Date().timeIntervalSince(since) >= quiet { break }
            try? await sleep(0.4)
        }
        return first != nil && first != last
    }

    /// The visible controls under `root` (a CSS selector), skipping anything inside `exclude`.
    public func extractFields(root: String? = nil, exclude: [String] = [], readOptions: Bool = true) async -> [FormField] {
        var args: [String: Any] = ["exclude": exclude]
        if let root { args["root"] = root }
        guard let raw = (try? await js(Scripts.extract, ["opts": args])) as? [[String: Any]] else { return [] }
        var fields: [FormField] = []
        for r in raw {
            guard let id = r["field_id"] as? String, let kind = FormField.Kind(rawValue: r["kind"] as? String ?? "") else { continue }
            let type = FieldSpec.FieldType(rawValue: r["field_type"] as? String ?? "text") ?? .text
            var current = (r["current_value"] as? String) ?? ""
            // "--" in a list that shows its choice as text (Paylocity's "permission to text you?") is no choice either.
            if (kind == .select || kind == .combobox) && isPlaceholderOption(current) { current = "" }
            let error = (r["error"] as? String) ?? ""
            let spec = FieldSpec(id: id, label: Self.withoutErrorNote((r["label"] as? String) ?? "", error: error), type: type,
                                 options: ((r["options"] as? [String]) ?? []).filter { !$0.isEmpty },
                                 required: (r["required"] as? Bool) ?? false, currentValue: current,
                                 placeholder: (r["placeholder"] as? String) ?? "", error: error,
                                 maxLength: (r["max_length"] as? NSNumber)?.intValue, section: (r["section"] as? String) ?? "")
            var f = FormField(spec: spec, kind: kind)
            f.name = (r["name"] as? String) ?? ""
            f.autocomplete = (r["autocomplete"] as? String) ?? ""
            f.htmlID = (r["html_id"] as? String) ?? ""
            f.isInput = (r["is_input"] as? Bool) ?? false
            f.spec.maxChoices = (r["max_choices"] as? NSNumber)?.intValue ?? 0
            fields.append(f)
        }
        if readOptions {
            for i in fields.indices where fields[i].kind == .combobox && fields[i].spec.currentValue.isEmpty {
                await loadComboboxOptions(&fields[i])
            }
        }
        return fields
    }

    private func visibleOptions(_ f: FormField) async -> [String] { await visibleOptions(f.selector) }

    private func visibleOptions(_ selector: String) async -> [String] {
        ((try? await js(Scripts.options, ["sel": selector])) as? [String]) ?? []
    }

    /// The options a list shows once it has finished looking ("Searching…" comes first in lists filled from the
    /// server). In the order the page tagged them, messages included.
    private func settledOptions(_ selector: String) async -> [String] {
        let busy = Regex(#"^(searching|loading)\b"#)
        for _ in 0..<10 {
            let options = await visibleOptions(selector)
            if !options.contains(where: busy.matches) { return options }
            try? await sleep(0.5)
        }
        return []
    }

    /// A list's message rather than a choice: "No results found", "Please enter 1 or more characters".
    static let listMessage = Regex(#"^(no (results|matches|options)( found)?|please enter \d+ or more characters?|searching|loading)\b"#)

    /// Opens a dropdown to read its options; long or remote lists are treated as type-to-search boxes.
    nonisolated static let requiredNote = #"\s*(this (field|question|answer) is required|(this is a )?required (field|question)|"#
        + #"please (make a selection|select an option|choose an option|answer this question|fill (in|out) this field)|field is required)\.?$"#

    /// A label that took in the field's error message ("Are you currently a student? This field is required"), which
    /// would make it another question for the answers saved before.
    nonisolated static func withoutErrorNote(_ label: String, error: String) -> String {
        var l = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = error.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty, l.count > e.count + 3, l.lowercased().hasSuffix(e.lowercased()) { l = String(l.dropLast(e.count)) }
        if let re = try? NSRegularExpression(pattern: requiredNote, options: [.caseInsensitive]),
           let m = re.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)), m.range.location > 3 {
            l = (l as NSString).substring(to: m.range.location)
        }
        return l.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func loadComboboxOptions(_ f: inout FormField) async {
        var options: [String] = []
        if await click(f.selector) {
            try? await sleep(0.5)
            options = await visibleOptions(f)
            await press(.escape, selector: f.selector)
        }
        options = options.filter { !$0.isEmpty && !isPlaceholderOption($0) && !["no options", "loading..."].contains($0.lowercased()) }
        if (1...80).contains(options.count) {
            f.spec.options = options
        } else {
            f.typeahead = true
            f.spec.type = .text
        }
    }

    /// Writes an answer into a control. Returns false if the control didn't take it.
    public func fill(_ f: FormField, _ answer: String) async -> Bool {
        switch f.kind {
        case .text:
            var value = answer
            if let max = f.spec.maxLength, max > 0, value.count > max { value = String(value.prefix(max)) }
            if await fill(f.selector, value) { return true }
            // A box that becomes the browser's own date picker once it has the focus (Paylocity's "Available to
            // Start", shown as MM/DD/YYYY) takes a date only as 2026-12-15.
            if let g = Regex(#"^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})$"#).firstGroups(value.trimmed), let m = g[1], let d = g[2], let y = g[3],
               let mi = Int(m), let di = Int(d) {
                let (month, day) = f.spec.placeholder.lowercased().hasPrefix("dd") ? (di, mi) : (mi, di)
                return await fill(f.selector, String(format: "%@-%02d-%02d", y, month, day))
            }
            return false
        case .select:
            if await selectOption(f.selector, label: answer) { return true }
            if let choice = matchOption(answer, f.spec.options) { return await selectOption(f.selector, label: choice) }
            return false
        case .radio, .buttons:
            guard let choice = matchOption(answer, f.spec.options), let i = f.spec.options.firstIndex(of: choice) else { return false }
            let sel = f.optionSelector(i)
            if f.kind == .radio, await isChecked(sel) { return true }
            await click(sel)
            try? await sleep(0.1)
            if f.kind == .buttons { return true }
            return await isChecked(sel)
        case .checkbox:
            let want = answer.trimmed.lowercased() == "yes"
            if await isChecked(f.selector) != want { await click(f.selector) }
            try? await sleep(0.1)
            return await isChecked(f.selector) == want
        case .checkboxGroup:
            var ok = true
            for part in answer.split(separator: ";").map({ String($0).trimmed }).filter({ !$0.isEmpty }) {
                guard let choice = matchOption(part, f.spec.options), let i = f.spec.options.firstIndex(of: choice) else { ok = false; continue }
                if !(await isChecked(f.optionSelector(i))) { await click(f.optionSelector(i)) }
            }
            return ok
        case .combobox:
            return await chooseCombobox(f, answer)
        case .file:
            return false
        }
    }

    private func chooseCombobox(_ f: FormField, _ answer: String) async -> Bool {
        // A search box that takes several choices, each becoming a chip (TCS's "Skills… (Maximum 5)"): one at a time,
        // only exact enough matches (never the first suggestion for a word that isn't there).
        if f.isInput && f.spec.maxChoices > 1 {
            let parts = answer.split(separator: ";").map { String($0).trimmed }.filter { !$0.isEmpty }
            var chosen = 0
            for part in parts where chosen < f.spec.maxChoices {
                if await chooseOne(f, part, multi: true) { chosen += 1 }
            }
            if chosen == 0 { await press(.escape) }
            return chosen > 0
        }
        return await chooseOne(f, answer, multi: false)
    }

    private func chooseOne(_ f: FormField, _ answer: String, multi: Bool) async -> Bool {
        await click(f.selector)
        // Where to type, and whose list to read: the box itself, or the search box its list opened (select2, whose
        // schools come from the server as you type: Infosys).
        var typeIn: String? = f.isInput ? f.selector : nil
        var listOf = f.selector
        if !f.isInput {
            try? await sleep(0.3)
            if await bool(Scripts.popupSearch, ["sel": f.selector]) {
                typeIn = #"[data-auto-search="1"]"#
                listOf = #"[data-auto-search="1"]"#
            }
        }
        var queries = [answer]
        if typeIn != nil, let short = answer.split(whereSeparator: { $0 == "," || $0 == "(" }).first.map({ String($0).trimmed }), !short.isEmpty, short != answer {
            queries.append(short)
        }
        for q in queries {
            if let typeIn { await fill(typeIn, q, keepFocus: true) }
            try? await sleep(0.9)
            // Suggestions fetched from the server can take a moment to show.
            var options: [String] = []
            var choices: [String] = []
            for _ in 0..<(typeIn == nil ? 1 : 5) {
                options = await settledOptions(listOf)
                choices = options.filter { !Self.listMessage.matches($0) }
                if !choices.isEmpty { break }
                try? await sleep(0.6)
            }
            guard !choices.isEmpty else { continue }
            var choice = matchOption(answer, choices) ?? matchOption(q, choices) ?? TimeZones.match(answer, choices)
            // A long list that draws only the rows in view and doesn't narrow as you type: scroll it to the answer (only the
            // answer itself: a near match in part of the list, "United Kingdom", isn't it).
            if choice == nil, await bool(Scripts.scrollToOption, ["sel": listOf, "want": [answer, q]]) {
                options = await visibleOptions(listOf)
                let key = { (t: String) in t.lowercased().filter { $0.isLetter || $0.isNumber } }
                choice = options.first { key($0) == key(answer) || key($0) == key(q) }
            }
            // A box that searches as you type shows the best guess first; a list that wasn't searched starts anywhere.
            if choice == nil && f.typeahead && typeIn != nil && !multi { choice = choices.first }
            // One of several: a suggestion that starts with the same name ("Raleigh, NC" → "Raleigh, North Carolina"),
            // never another word that merely starts the same way ("Go" isn't "Google Cloud").
            if choice == nil && multi, let head = q.split(separator: ",").first.map({ norm(String($0)) }), head.count >= 2 {
                let lead = Regex("^" + NSRegularExpression.escapedPattern(for: head) + #"(?![a-z0-9+#])"#)
                choice = choices.first { lead.matches(norm($0)) }
            }
            guard let choice, let i = options.firstIndex(of: choice) else { continue }
            await click(#"[data-auto-choice="\#(i)"]"#)
            if multi { try? await sleep(0.4); return true }
            if await choiceTook(f, choice) { return true }
            // The list closed as the mouse went down on the choice, so it was never chosen (Paylocity's Country once
            // it had read the resume: the box lost the focus and reverted to "Peru"). Again, pressed by script, which
            // leaves the focus in the box.
            Log.info("“\(choice)” didn't take in “\(f.spec.label.prefix(40))”; choosing it again")
            await click(f.selector)
            if let typeIn { await fill(typeIn, q, keepFocus: true) }
            try? await sleep(0.9)
            let again = await settledOptions(listOf)
            let key = { (t: String) in t.lowercased().filter { $0.isLetter || $0.isNumber } }
            if let j = again.firstIndex(where: { key($0) == key(choice) }) {
                // Already the chosen row (a list that shows its choice elsewhere): pressing it again could undo it.
                if await bool(#"const e = document.querySelector(sel); return !!e && (e.getAttribute('aria-selected') === 'true' || e.getAttribute('aria-checked') === 'true');"#,
                              ["sel": #"[data-auto-choice="\#(j)"]"#]) {
                    await press(.escape)
                    return true
                }
                await scriptClick(#"[data-auto-choice="\#(j)"]"#)
                if await choiceTook(f, choice) { return true }
            }
            await press(.escape)
            return false
        }
        if multi, let typeIn { await fill(typeIn, "", keepFocus: false) } else { await press(.escape) }
        // An address box that suggests addresses as you type but takes any (Paylocity's "Address Line 1"): the
        // address as typed.
        if !multi, f.isInput, Regex(#"\b(address|street)\b"#).matches(norm(f.spec.label)), await fill(f.selector, answer) {
            try? await sleep(0.3)
            let kept = (try? await js("const e = document.querySelector(sel); return e ? e.value : ''", ["sel": f.selector])) as? String
            if kept?.trimmed == answer.trimmed { return true }
        }
        return false
    }

    /// Whether a list box shows the choice just made. False only when it shows nothing, or still shows what it had
    /// before when that isn't the choice; true when the box can't be read (it was drawn again) or shows something else
    /// that may be the choice written another way.
    private func choiceTook(_ f: FormField, _ choice: String) async -> Bool {
        try? await sleep(0.35)
        let shown = try? await js("""
            const el = document.querySelector(sel);
            if (!el || !el.isConnected) return null;
            const clean = s => (s || '').replace(/\\s+/g, ' ').trim();
            const SV = '[class*="single-value" i], [class*="singleValue" i], [class*="selected-value" i], [data-automation-id="selectedItem"]';
            const sv = [el.closest('[aria-owns], [aria-controls], [aria-haspopup]'), el.labels && el.labels[0], el.parentElement && el.parentElement.parentElement]
              .filter(Boolean).map(x => x.querySelector(SV)).find(x => x && clean(x.innerText));
            if (sv) return clean(sv.innerText);
            return el.tagName === 'INPUT' ? clean(el.value) : clean(el.innerText);
            """, ["sel": f.selector])
        guard let text = shown as? String else { return true }
        if text.isEmpty { return !f.isInput }
        let key = { (t: String) in t.lowercased().filter { $0.isLetter || $0.isNumber } }
        if key(text) == key(choice) || matchOption(choice, [text]) != nil { return true }
        return !(key(text) == key(f.spec.currentValue) && !f.spec.currentValue.isEmpty)
    }

    public func upload(_ f: FormField, _ file: URL) async -> Bool {
        await setFiles(f.selector, [file])
    }

    public func collectErrors(root: String? = nil) async -> [String: String] {
        var args: [String: Any] = ["rootSel": NSNull()]
        if let root { args["rootSel"] = root }
        return ((try? await js(Scripts.errors, args)) as? [String: String]) ?? [:]
    }

    /// Finds the last visible enabled button whose name matches `pattern` (case-insensitive). Returns its name and
    /// tags it so `clickFoundButton` can press it.
    public func findButton(_ pattern: String, root: String? = nil) async -> String? {
        var args: [String: Any] = ["pattern": pattern, "flags": "i", "rootSel": NSNull()]
        if let root { args["rootSel"] = root }
        return (try? await js(Scripts.findButton, args)) as? String
    }

    @discardableResult
    public func clickFoundButton() async -> Bool { await click(#"[data-auto-btn="1"]"#) }

    /// Tags a button named like `pattern`, else the form's primary button, for `clickFoundButton`. False when neither.
    public func hasButton(_ pattern: String) async -> Bool {
        if await findButton(pattern) != nil { return true }
        return await findPrimaryButton() != nil
    }

    public func fieldCount() async -> Int { ((try? await js(Scripts.countFields)) as? NSNumber)?.intValue ?? 0 }

    public func hasPasswordField() async -> Bool { await bool(Scripts.hasPassword) }

    // MARK: getting to the form

    /// Closes cookie and privacy banners (declining optional cookies where the banner offers it). Returns the names
    /// of the buttons it pressed.
    @discardableResult
    public func dismissBanners() async -> [String] {
        var pressed: [String] = []
        for _ in 0..<3 {
            let name = await string(Scripts.tagBannerButton)
            guard !name.isEmpty else { break }
            await click(#"[data-auto-banner="1"]"#)
            pressed.append(name)
            try? await sleep(0.6)
        }
        if !pressed.isEmpty { Log.info("Closed a cookie or privacy banner (\(pressed.joined(separator: ", ")))") }
        return pressed
    }

    /// Closes a popup offering to fill the form from the resume: the app fills it from the profile (the resume's
    /// guesses put an old address in), and lists searched by typing don't work while it's open. Returns the name of
    /// the button it pressed.
    @discardableResult
    public func closeResumeImport() async -> String? {
        let name = await string(Scripts.tagResumeImportClose)
        guard !name.isEmpty else { return nil }
        await click(#"[data-auto-dialog-close="1"]"#)
        try? await sleep(0.8)
        Log.info("Closed a popup offering to fill the form from the resume (\(name))")
        return name
    }

    public struct PageKind: Sendable {
        public enum Kind: String, Sendable { case page, botcheck, closed, error, emaillink }
        public var kind: Kind
        public var fields: Int
        public var passwords: Int
        public var text: String
        /// An error page with nothing of the site's own around it.
        public var bare = false
        /// An image puzzle ("Click on items that are tied…"), which the app never solves.
        public var puzzle = false
        /// A box for a resume, even one whose file input is hidden behind a drop zone.
        public var upload = false
    }

    public func pageKind() async -> PageKind {
        // A page that draws its form in a frame of its own (iCIMS): the frame is the page from here on.
        let framed = await string(Scripts.tagSelfFrame)
        if !framed.isEmpty { Log.info("Working inside the frame that holds the form: \(framed.prefix(120))") }
        let r = (try? await js(Scripts.pageKind)) as? [String: Any] ?? [:]
        return PageKind(kind: PageKind.Kind(rawValue: r["kind"] as? String ?? "") ?? .page, fields: (r["fields"] as? NSNumber)?.intValue ?? 0,
                        passwords: (r["passwords"] as? NSNumber)?.intValue ?? 0, text: r["text"] as? String ?? "",
                        bare: (r["bare"] as? Bool) ?? false, puzzle: (r["puzzle"] as? Bool) ?? false, upload: (r["upload"] as? Bool) ?? false)
    }

    /// An "I'm not a robot" box on the page. The app never ticks one: only the user may.
    public func hasRobotBox() async -> Bool {
        (try? await js(Scripts.robotBox)) as? Bool ?? false
    }

    /// Waits for a bot check that runs by itself ("Performing security verification…") to finish. False if it's still
    /// showing after `timeout`, or at once for a picture puzzle (it wants a person, and never finishes by itself).
    public func waitOutBotCheck(timeout: TimeInterval = 25) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let page = await pageKind()
            if page.kind != .botcheck { return true }
            if page.puzzle || Date() > deadline || Task.isCancelled { return false }
            try? await sleep(1)
        }
    }

    /// Why the app stopped at a bot check, in the user's words.
    public func botCheckNote(_ site: String) async -> String {
        await pageKind().puzzle
            ? "\(site) showed a picture puzzle to prove you're a person. The app never solves those; apply on their site yourself."
            : "\(site) showed an “are you human?” check the app can't pass."
    }

    /// Presses the button or follows the link that leads from a careers page to its application ("Apply now",
    /// "Proceed"). A link to another page is opened in this tab: clicking one that opens a new tab can be blocked as a
    /// pop-up. Returns its name, or nil when there's none.
    /// `anyButton` also allows plain "Proceed" / "Continue" / "I agree" (only on a page without fields, where they
    /// can't be a form's own button).
    public func followEntry(anyButton: Bool = true) async throws -> String? {
        guard let r = (try? await js(Scripts.tagEntryButton, ["anyButton": anyButton])) as? [String: Any], let name = r["name"] as? String else { return nil }
        let before = url
        if let href = r["href"] as? String, let link = URL(string: href),
           link.scheme?.hasPrefix("http") == true || (link.isFileURL && before?.isFileURL == true) {
            try await load(link)
        } else {
            await click(#"[data-auto-entry="1"]"#)
            try await sleep(2)
            if url != before { try? await waitForLoad() }
        }
        try await sleep(1)
        return name
    }

    public struct AccountForm: Sendable {
        public enum Kind: String, Sendable { case register, login }
        public var kind: Kind
        public var passwords: Int
        public var button: String
        public var hasUser: Bool
        /// A resume upload for first-time visitors next to a sign-in box.
        public var firstTimeUpload: Bool
    }

    /// The sign-in or sign-up box on the page, if there's a visible password box (tags its parts; see Scripts).
    public func accountForm() async -> AccountForm? {
        guard let r = (try? await js(Scripts.tagAccountForm)) as? [String: Any], let k = AccountForm.Kind(rawValue: r["kind"] as? String ?? "") else { return nil }
        return AccountForm(kind: k, passwords: (r["passwords"] as? NSNumber)?.intValue ?? 1, button: r["button"] as? String ?? "",
                           hasUser: (r["user"] as? Bool) ?? false, firstTimeUpload: (r["upload"] as? Bool) ?? false)
    }

    /// Types `email` into the page's box for an email address (or user name). With `onlyEmpty`, leaves one that
    /// already holds something. False when there's no such box.
    @discardableResult
    public func fillEmailBox(_ email: String, onlyEmpty: Bool = false) async -> Bool {
        guard let current = (try? await js(Scripts.tagEmailBox)) as? String else { return false }
        if onlyEmpty && !current.isEmpty { return true }
        return await fill(#"[data-auto-emailbox="1"]"#, email)
    }

    /// Types `password` into every empty password box on the page. Returns how many it filled.
    @discardableResult
    public func fillPasswords(_ password: String) async -> Int {
        ((try? await js(Scripts.fillPasswords, ["value": password])) as? NSNumber)?.intValue ?? 0
    }

    /// A popup over the form that wants something first (a privacy statement to agree to, with its own Save), tagged
    /// for `blockingDialogRoot`; its heading, or nil.
    public func blockingDialog() async -> String? {
        let name = await string(Scripts.tagBlockingDialog)
        return name.isEmpty ? nil : name
    }

    public static let blockingDialogRoot = #"[data-auto-modal="1"]"#

    /// The form's own submit button when its name isn't one the handlers know ("Verify", "Send code"); tagged for
    /// `clickFoundButton`.
    public func findPrimaryButton(root: String? = nil) async -> String? {
        var args: [String: Any] = ["rootSel": NSNull()]
        if let root { args["rootSel"] = root }
        return (try? await js(Scripts.tagPrimaryButton, args)) as? String
    }
}
