import Foundation

/// LinkedIn's own Easy Apply dialog.
final class EasyApplyHandler: ApplicationHandler {
    override class var ats: ATSType { .easyApply }
    override class var exclude: [String] { ["#follow-company-checkbox", "[class*=follow-company]", "header", "footer"] }

    static let root = #"[data-auto-root="easy-apply"]"#
    static let submit = #"^submit application$"#
    static let review = #"^review( your application)?$"#
    static let next = #"^(next|continue to next step|continue)$"#
    static let sent = Regex(#"application (was )?sent|your application was sent|application submitted"#)

    override func apply() async throws -> ApplyResult {
        guard await openDialog() else { return await failure("The Easy Apply dialog didn't open.") }
        do {
            let result = try await run()
            if result.status != .applied { await discard() }
            return result
        } catch {
            await discard()
            throw error
        }
    }

    private func modalProgress() async -> String? {
        (try? await web.js(Scripts.tagEasyApplyModal)) as? String
    }

    private func openDialog() async -> Bool {
        guard await web.click(#"[data-auto-apply="1"]"#) else { return false }
        guard await web.waitFor(".jobs-easy-apply-modal, [role=dialog]", visible: true, timeout: 10) else { return false }
        try? await web.sleep(1.2)
        return await modalProgress() != nil
    }

    private func run() async throws -> ApplyResult {
        let root = Self.root
        var lastState: String?
        var stuck = 0
        for _ in 0..<ctx.limits.maxFormSteps {
            try Task.checkCancellation()
            guard let progress = await modalProgress() else { return await failure("The Easy Apply dialog closed unexpectedly.") }
            let outcome = try await fillStep(root: root)
            if let blocked = outcome.blocked { return needsAnswer(blocked) }
            if !outcome.missingFiles.isEmpty { return await failure("Couldn't attach: \(outcome.missingFiles.joined(separator: ", "))") }
            await uncheckFollow()

            let state = progress + "|" + outcome.fields.map(\.spec.label).sorted().joined(separator: "|")
            stuck = state == lastState ? stuck + 1 : 0
            if stuck >= 2 { return await failure("Easy Apply didn't move on (same page three times).") }
            lastState = state

            if await web.findButton(Self.submit, root: root) != nil {
                if ctx.practice { return await practiceResult() }
                ctx.step("Submitting")
                let (advanced, result) = try await clickAndValidate(root: root) { await web.findButton(Self.submit, root: root) != nil }
                if !advanced { return result! }
                return await confirm()
            }
            let pattern = await web.findButton(Self.review, root: root) != nil ? Self.review : Self.next
            guard await web.findButton(pattern, root: root) != nil else { return await failure("No Next, Review or Submit button in the Easy Apply dialog.") }
            let (advanced, result) = try await clickAndValidate(root: root) { await web.findButton(pattern, root: root) != nil }
            if !advanced { return result! }
            ctx.step(pattern == Self.review ? "Reviewing the application" : "Next page of the form")
            try await stepPause()
        }
        return await failure("Easy Apply went past \(ctx.limits.maxFormSteps) pages.")
    }

    /// LinkedIn keeps resumes uploaded before; if one is already selected, don't upload another copy.
    override func handleDocuments(_ fields: [FormField]) async throws -> (handled: Set<String>, missing: [String]) {
        if await web.bool(Scripts.easyApplyResumeSelected) {
            let resumeIDs = Set(fields.filter { $0.kind == .file && !$0.spec.label.lowercased().contains("cover") }.map(\.id))
            let (handled, missing) = try await super.handleDocuments(fields.filter { !resumeIDs.contains($0.id) })
            return (handled.union(resumeIDs), missing)
        }
        return try await super.handleDocuments(fields)
    }

    private func uncheckFollow() async {
        let box = "\(Self.root) #follow-company-checkbox"
        guard await web.isChecked(box) else { return }
        if await web.isVisible(#"\#(Self.root) label[for="follow-company-checkbox"]"#) {
            await web.click(#"\#(Self.root) label[for="follow-company-checkbox"]"#)
        } else {
            await web.click(box)
        }
    }

    private func confirm() async -> ApplyResult {
        for _ in 0..<15 {
            if Self.sent.matches(await web.text()) {
                let evidence = await saveEvidence("Sent")
                await closeDialogs()
                return ApplyResult(.applied, notes: "Sent with LinkedIn Easy Apply", evidence: evidence)
            }
            try? await web.sleep(1)
        }
        if await confirmSubmitted(timeout: 3) {
            let evidence = await saveEvidence("Sent")
            await closeDialogs()
            return ApplyResult(.applied, notes: "Sent with LinkedIn Easy Apply", evidence: evidence)
        }
        return await failure("Pressed Submit but LinkedIn didn't confirm the application was sent.")
    }

    private func closeDialogs() async {
        for pattern in [#"^(done|not now)$"#, #"^dismiss$"#] where await web.findButton(pattern, root: "[role=dialog]") != nil {
            await web.clickFoundButton()
            try? await web.sleep(0.5)
        }
    }

    /// Closes the dialog without submitting (LinkedIn asks whether to save or discard).
    private func discard() async {
        let dismiss = #"\#(Self.root) button[aria-label="Dismiss"], \#(Self.root) button[aria-label*="Dismiss"]"#
        if await web.exists(dismiss) { await web.click(dismiss) } else { await web.press(.escape) }
        try? await web.sleep(0.8)
        let confirmButton = #"button[data-control-name="discard_application_confirm_btn"]"#
        if await web.exists(confirmButton) {
            await web.click(confirmButton)
        } else if await web.findButton(#"^discard$"#, root: "[role=dialog], [role=alertdialog]") != nil {
            await web.clickFoundButton()
        }
        try? await web.sleep(0.5)
    }
}

/// Greenhouse (boards.greenhouse.io, job-boards.greenhouse.io, embedded forms). After the first Submit it may ask
/// for an 8-character security code it emailed; the code is read from the inbox and the form submitted again.
final class GreenhouseHandler: ApplicationHandler {
    override class var ats: ATSType { .greenhouse }
    static let formSelectors = ["#application-form", "#application_form", "form[action*='greenhouse']", "form#application"]
    static let codeInputs = "#security-input-0, input[id^='security-input-'], #security_code, input[name='security_code']"

    private func formRoot() async -> String? {
        for sel in Self.formSelectors where await web.exists(sel) { return sel }
        return nil
    }

    override func apply() async throws -> ApplyResult {
        var root = await formRoot()
        if root == nil {
            try await clickApplyEntry()
            try await web.sleep(1.5)
            root = await formRoot()
        }
        guard let root else { return await failure("Couldn't find the Greenhouse application form.") }
        return try await runFormFlow(root: root)
    }

    override func afterSubmit(submittedAt: Date) async throws -> ApplyResult? {
        guard await web.waitFor(Self.codeInputs, visible: true, timeout: 8) else { return nil }
        ctx.step("Greenhouse emailed a security code — checking your inbox")
        guard ctx.verifier.configured else {
            return await failure("Greenhouse emailed a security code, but email isn't connected (Settings › Email codes).", .failedOTPTimeout)
        }
        let result = await ctx.verifier.waitForVerification(senderHint: "greenhouse", since: submittedAt, timeout: TimeInterval(ctx.limits.otpTimeoutSec),
                                                            kind: .code, codeLength: 8)
        guard let code = result?.code else {
            return await failure("No Greenhouse security code arrived within \(ctx.limits.otpTimeoutSec) seconds.", .failedOTPTimeout)
        }
        ctx.step("Entering the security code")
        if await web.exists("#security_code, input[name='security_code']") {
            await web.fill("#security_code, input[name='security_code']", code)
        } else {
            for (i, ch) in code.enumerated() where await web.exists("#security-input-\(i)") {
                await web.fill("#security-input-\(i)", String(ch))
            }
        }
        guard await web.findButton(submitPattern) != nil else { return await failure("Entered the security code but found no Submit button.") }
        await web.clickFoundButton()
        try await web.sleep(2.5)
        return nil
    }
}

/// Lever (jobs.lever.co/<company>/<id>/apply).
final class LeverHandler: ApplicationHandler {
    override class var ats: ATSType { .lever }
    static let form = "#application-form, form[action*='/apply'], form.application-form"

    override func apply() async throws -> ApplyResult {
        if let url = web.url, !url.path.hasSuffix("/apply"), var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.path = (c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path) + "/apply"
            c.query = nil
            if let u = c.url { try await web.load(u) }
        }
        guard await web.waitFor(Self.form, timeout: 15) else { return await failure("Couldn't find the Lever application form.") }
        await preuploadResume()
        return try await runFormFlow(root: Self.form)
    }

    /// Lever reads the resume and pre-fills fields: upload it first so that can't overwrite the answers.
    private func preuploadResume() async {
        let input = "\(Self.form.split(separator: ",")[0]) input[type=file][name=resume], form input[type=file][name=resume]"
        guard await web.exists(input), await web.setFiles(input, [ctx.paths.resumeFile]) else { return }
        ctx.step("Attached your resume")
        if await web.waitFor(".resume-upload-success, .resume-upload-working", timeout: 4) {
            for _ in 0..<60 where await web.isVisible(".resume-upload-working") { try? await web.sleep(0.25) }
        } else {
            try? await web.sleep(3)
        }
    }
}

/// Ashby (jobs.ashbyhq.com/<company>/<id>/application).
final class AshbyHandler: ApplicationHandler {
    override class var ats: ATSType { .ashby }
    // The "Autofill from resume" widget re-reads the resume later and can overwrite answers.
    override class var exclude: [String] { super.exclude + ["[class*=autofill i]"] }

    override func apply() async throws -> ApplyResult {
        if let url = web.url, !url.path.hasSuffix("/application") {
            if await web.findButton(#"^application$"#) != nil {
                await web.clickFoundButton()
                try await web.sleep(1)
            } else if var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                c.path = (c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path) + "/application"
                if let u = c.url { try await web.load(u) }
            }
        }
        guard await web.waitFor("input[type=file], input[type=email], #_systemfield_name", timeout: 15) else {
            return await failure("Couldn't find the Ashby application form.")
        }
        return try await runFormFlow(root: nil)
    }
}

/// Workday: Apply → Autofill with Resume / Apply Manually → sign in or create an account → the multi-page wizard.
/// Accounts use the profile's email and the portal password the app generated; a new account's verification link is
/// read from the inbox.
final class WorkdayHandler: ApplicationHandler {
    override class var ats: ATSType { .workday }
    static func aid(_ name: String) -> String { #"[data-automation-id="\#(name)"]"# }
    override class var exclude: [String] {
        super.exclude + [aid("utilityButtonBar"), aid("navigationPanel"), aid("multiselectInputContainer"),
                         aid("dateSectionMonth-input"), aid("dateSectionDay-input"), aid("dateSectionYear-input")]
    }
    static let nextButton = "\(aid("bottom-navigation-next-button")), \(aid("pageFooterNextButton"))"
    static let success = Regex(#"application (has been )?submitted|congratulations|thank you for applying"#)
    static let verifyPrompt = Regex(#"verify your (email|account)|verification email|check your email|account (has not been|isn't) verified"#)

    private func visible(_ name: String) async -> Bool { await web.isVisible(Self.aid(name)) }

    override func apply() async throws -> ApplyResult {
        try await web.sleep(2.5)
        if await visible("adventureButton") {
            await web.click(Self.aid("adventureButton"))
            try await web.sleep(2)
        }
        var usedAutofill = try await chooseStart()
        if let gate = try await signIn() { return gate }
        let autofillOffered = await visible("autofillWithResume")
        if usedAutofill || autofillOffered {
            let chose = try await chooseStart()
            usedAutofill = chose || usedAutofill
            await uploadResume()
        }
        for _ in 0..<ctx.limits.maxFormSteps {
            try Task.checkCancellation()
            try await waitIdle()
            if Self.success.matches(await web.text()) {
                return ApplyResult(.applied, notes: "Sent through Workday", evidence: await saveEvidence("Sent"), externalURL: web.url?.absoluteString)
            }
            let label = await web.string(Scripts.prelude + "const b = [...document.querySelectorAll(sel)].find(shown); return b ? clean(b.innerText) : '';",
                                         ["sel": Self.nextButton])
            guard !label.isEmpty else { return await failure("Workday: no Next or Submit button on this page.") }
            if Regex(#"^submit"#).matches(label) {
                if ctx.practice { return await practiceResult() }
                ctx.step("Submitting")
                await web.click(Self.nextButton)
                try await web.sleep(4)
                if await confirmSubmitted() {
                    return ApplyResult(.applied, notes: "Sent through Workday", evidence: await saveEvidence("Sent"), externalURL: web.url?.absoluteString)
                }
                return await failure("Workday: pressed Submit but saw no confirmation.")
            }
            await fillSource()
            await fillTodayDates()
            let outcome = try await fillStep(root: nil)
            if let blocked = outcome.blocked { return needsAnswer(blocked) }
            let (advanced, result) = try await clickAndValidate(root: nil) {
                await web.bool(Scripts.prelude + "document.querySelectorAll('[data-auto-btn]').forEach(b => b.removeAttribute('data-auto-btn'));" +
                               "const b = [...document.querySelectorAll(sel)].find(shown); if (b) b.setAttribute('data-auto-btn', '1'); return !!b;",
                               ["sel": Self.nextButton])
            }
            if !advanced { return result! }
            ctx.step("Next page of the form")
            try await stepPause()
        }
        return await failure("Workday: went past \(ctx.limits.maxFormSteps) pages.")
    }

    private func waitIdle() async throws {
        for _ in 0..<32 where web.webView.isLoading { try await web.sleep(0.25) }
        try await web.sleep(0.8)
    }

    /// Prefers "Autofill with Resume", else "Apply Manually". True if autofill was chosen.
    private func chooseStart() async throws -> Bool {
        for (name, autofill) in [("autofillWithResume", true), ("applyManually", false)] where await visible(name) {
            await web.click(Self.aid(name))
            try await web.sleep(2.5)
            return autofill
        }
        return false
    }

    private func pressSubmit(_ name: String) async {
        let overlay = "\(Self.aid(name)) \(Self.aid("click_filter"))"
        await web.click(await web.exists(overlay) ? overlay : Self.aid(name))
    }

    private func signIn() async throws -> ApplyResult? {
        guard await visible("email") else { return nil }
        let password = ctx.secrets.portalPassword
        guard !password.isEmpty else { return await failure("Workday needs an account, but no portal password is set (Settings › Accounts).") }
        let email = ctx.profile.personal.email
        if !(await visible("verifyPassword")) {
            if try await trySignIn(email, password) { return nil }
            if await visible("createAccountLink") {
                await web.click(Self.aid("createAccountLink"))
                try await web.sleep(1.5)
            }
        }
        guard await visible("verifyPassword") else { return nil }
        ctx.step("Creating a Workday account for \(ctx.company)")
        let createdAt = Date()
        await web.fill(Self.aid("email"), email)
        await web.fill(Self.aid("password"), password)
        await web.fill(Self.aid("verifyPassword"), password)
        if await visible("createAccountCheckbox"), !(await web.isChecked(Self.aid("createAccountCheckbox"))) {
            await web.click(Self.aid("createAccountCheckbox"))
        }
        await pressSubmit("createAccountSubmitButton")
        try await web.sleep(4)
        let errors = await web.collectErrors()
        let errorShown = await visible("errorMessage")
        if !errors.isEmpty || errorShown {
            let msg = errors.isEmpty ? String(await web.text(maxChars: 400)) : errors.values.joined(separator: "; ")
            return await failure("Workday didn't create the account: \(msg.prefix(200))")
        }
        let pageText = await web.text()
        let emailShown = await visible("email")
        if Self.verifyPrompt.matches(pageText) || emailShown {
            if let res = try await verifyEmail(since: createdAt) { return res }
            if await visible("email"), !(try await trySignIn(email, password)) {
                return await failure("Workday: couldn't sign in after creating the account.")
            }
        }
        return nil
    }

    private func trySignIn(_ email: String, _ password: String) async throws -> Bool {
        if await visible("signInLink") {
            await web.click(Self.aid("signInLink"))
            try await web.sleep(1.2)
        }
        guard await visible("email") else { return true }
        ctx.step("Signing in to Workday")
        await web.fill(Self.aid("email"), email)
        await web.fill(Self.aid("password"), password)
        await pressSubmit("signInSubmitButton")
        try await web.sleep(4)
        let stillAsking = await visible("email")
        let failed = await visible("errorMessage")
        return !stillAsking && !failed
    }

    private func verifyEmail(since: Date) async throws -> ApplyResult? {
        guard ctx.verifier.configured else {
            return await failure("Workday sent a verification email, but email isn't connected (Settings › Email codes).", .failedOTPTimeout)
        }
        ctx.step("Waiting for Workday's verification email")
        guard let res = await ctx.verifier.waitForVerification(senderHint: "workday|myworkday", since: since,
                                                               timeout: TimeInterval(ctx.limits.otpTimeoutSec), kind: .link),
              let link = res.url, let url = URL(string: link) else {
            return await failure("Workday's verification email didn't arrive in time.", .failedOTPTimeout)
        }
        let back = web.url
        try await web.load(url)
        try await web.sleep(3)
        if let back { try await web.load(back) }
        try await web.sleep(2.5)
        return nil
    }

    private func uploadResume() async {
        let input = "\(Self.aid("file-upload-input-ref")), input[type=file]"
        if await web.exists(input), await web.setFiles(input, [ctx.paths.resumeFile]) {
            ctx.step("Attached your resume")
            try? await web.sleep(5)  // Workday reads the resume
        }
    }

    /// "How Did You Hear About Us?" is a nested multi-select prompt.
    private func fillSource() async {
        let source = ctx.profile.preferences.howDidYouHear.isEmpty ? "LinkedIn" : ctx.profile.preferences.howDidYouHear
        let count = ((try? await web.js("return document.querySelectorAll(sel).length", ["sel": Self.aid("multiselectInputContainer")])) as? NSNumber)?.intValue ?? 0
        for i in 0..<count {
            let tagged = await web.bool("""
                const box = document.querySelectorAll(sel)[i]; if (!box) return false;
                const group = box.closest('[data-automation-id^="formField"]') || box.parentElement;
                const q = (group ? group.innerText : '').toLowerCase();
                if (!/how did you hear|source/.test(q) || box.querySelector('[data-automation-id="selectedItem"]')) return false;
                document.querySelectorAll('[data-auto-src]').forEach(e => e.removeAttribute('data-auto-src'));
                const input = box.querySelector('input'); if (!input) return false;
                input.setAttribute('data-auto-src', '1'); return true;
                """, ["sel": Self.aid("multiselectInputContainer"), "i": i])
            guard tagged else { continue }
            await web.click(#"[data-auto-src="1"]"#)
            await web.fill(#"[data-auto-src="1"]"#, source, keepFocus: true)
            await web.press(.enter)
            try? await web.sleep(1.5)
            let options = ((try? await web.js(Scripts.prelude + "return [...document.querySelectorAll(sel)].filter(shown).map(o => clean(o.innerText));",
                                              ["sel": Self.aid("promptOption")])) as? [String]) ?? []
            guard let choice = matchOption(source, options) ?? options.first, let idx = options.firstIndex(of: choice) else { continue }
            await web.bool(Scripts.prelude + "const o = [...document.querySelectorAll(sel)].filter(shown)[i]; if (o) o.setAttribute('data-auto-pick', '1'); return !!o;",
                           ["sel": Self.aid("promptOption"), "i": idx])
            await web.click(#"[data-auto-pick="1"]"#)
            try? await web.sleep(0.8)
        }
    }

    /// Self-identification pages ask for today's date in separate month/day/year boxes.
    private func fillTodayDates() async {
        let f = DateFormatter()
        for (part, format) in [("Month", "MM"), ("Day", "dd"), ("Year", "yyyy")] {
            f.dateFormat = format
            let value = f.string(from: Date())
            let sel = Self.aid("dateSection\(part)-input")
            let count = ((try? await web.js("return document.querySelectorAll(sel).length", ["sel": sel])) as? NSNumber)?.intValue ?? 0
            for i in 0..<count {
                let ok = await web.bool(Scripts.prelude + """
                    const e = document.querySelectorAll(sel)[i];
                    if (!e || !shown(e) || (e.value || '').trim()) return false;
                    const f = e.closest('[data-automation-id^="formField"]') || e.closest('fieldset');
                    const l = f && f.querySelector('label, legend');
                    if (!/\\bdate\\b|signed|today/i.test(l ? l.innerText : '')) return false;
                    document.querySelectorAll('[data-auto-date]').forEach(x => x.removeAttribute('data-auto-date'));
                    e.setAttribute('data-auto-date', '1'); return true;
                    """, ["sel": sel, "i": i])
                if ok { await web.fill(#"[data-auto-date="1"]"#, value) }
            }
        }
    }
}

/// Which handler suits an application page.
enum SiteRouter {
    static func detect(_ url: URL) -> ATSType {
        let host = url.host?.lowercased() ?? ""
        if host.hasSuffix("greenhouse.io") || (url.query ?? "").contains("gh_jid=") { return .greenhouse }
        if host.hasSuffix("lever.co") { return .lever }
        if host.hasSuffix("ashbyhq.com") { return .ashby }
        if Regex(#"(myworkdayjobs|myworkdaysite)\.com$|\.workday\.com$"#).matches(host) { return .workday }
        return .generic
    }

    @MainActor
    static func handler(_ ats: ATSType) -> ApplicationHandler.Type {
        switch ats {
        case .greenhouse: GreenhouseHandler.self
        case .lever: LeverHandler.self
        case .ashby: AshbyHandler.self
        case .workday: WorkdayHandler.self
        case .easyApply: EasyApplyHandler.self
        case .generic: GenericHandler.self
        }
    }

    /// Careers pages often embed Greenhouse, Lever or Ashby in a frame: open the frame's page directly.
    @MainActor
    static func resolveEmbedded(_ web: WebAgent) async throws -> ATSType {
        let frames = ((try? await web.js(Scripts.frames)) as? [[String: Any]]) ?? []
        for f in frames {
            guard let src = f["src"] as? String, let url = URL(string: src) else { continue }
            let ats = detect(url)
            if [.greenhouse, .lever, .ashby].contains(ats) {
                Log.info("Opening the embedded \(ats.label) form: \(src)")
                try await web.load(url)
                return ats
            }
        }
        // A form in a frame from another site: open the biggest visible frame that holds inputs.
        if await web.fieldCount() < 3, let big = frames.first(where: { ($0["shown"] as? Bool) == true && (($0["area"] as? NSNumber)?.intValue ?? 0) > 150_000 }),
           let src = big["src"] as? String, let url = URL(string: src), !src.contains("youtube"), !src.contains("vimeo") {
            try await web.load(url)
        }
        return web.url.map(detect) ?? .generic
    }
}
