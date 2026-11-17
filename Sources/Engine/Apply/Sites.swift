import Foundation

/// LinkedIn's own Easy Apply dialog.
final class EasyApplyHandler: ApplicationHandler {
    override class var ats: ATSType { .easyApply }
    override class var exclude: [String] { ["#follow-company-checkbox", "[class*=follow-company]", "header", "footer"] }

    static let root = #"[data-auto-root="easy-apply"]"#
    // LinkedIn shows the member's own language; English and Spanish are covered.
    static let submit = #"^(submit application|enviar solicitud)$"#
    static let review = #"^(review( your application)?|revisar( tu solicitud)?)$"#
    static let next = #"^(next|continue to next step|continue|siguiente|continuar|ir al siguiente paso)$"#
    static let sent = Regex(#"application (was )?sent|your application was sent|application submitted|solicitud enviada|se (ha )?envi(ó|o) tu solicitud|tu solicitud (se ha enviado|fue enviada)"#)

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
        let deadline = Date().addingTimeInterval(12)
        var reminded = false
        while Date() < deadline {
            try? await web.sleep(0.4)
            if await modalProgress() != nil {
                try? await web.sleep(1.2)  // let it finish drawing
                return await modalProgress() != nil
            }
            // LinkedIn's "Job search safety reminder" (look the company up first) comes before the form, once.
            if !reminded, let name = await web.findButton(#"^continue applying$"#) {
                reminded = true
                Log.info("Pressed “\(name)” past LinkedIn's job search safety reminder")
                ctx.step("Pressed “\(name)” past LinkedIn's safety reminder")
                await web.clickFoundButton()
            }
        }
        return false
    }

    private func run() async throws -> ApplyResult {
        let root = Self.root
        var lastState: String?
        var stuck = 0
        for _ in 0..<ctx.limits.maxFormSteps {
            try Task.checkCancellation()
            guard let progress = await modalProgress() else { return await failure("The Easy Apply dialog closed unexpectedly.") }
            let outcome = try await fillStep(root: root)
            if let stop = outcome.stop { return stop }
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

    override var lookForHiddenResumeBox: Bool { false }

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
        for pattern in [#"^(done|not now|listo|ahora no)$"#, #"^(dismiss|descartar|cerrar)$"#] {
            for root in [Self.root, "[role=dialog]"] where await web.findButton(pattern, root: root) != nil {
                await web.clickFoundButton()
                try? await web.sleep(0.5)
                break
            }
        }
    }

    /// Closes the dialog without submitting (LinkedIn asks whether to save or discard).
    private func discard() async {
        let dismiss = #"\#(Self.root) button[aria-label="Dismiss"], \#(Self.root) button[aria-label*="Dismiss"], \#(Self.root) button[aria-label="Descartar"], \#(Self.root) button[aria-label="Cerrar"]"#
        if await web.exists(dismiss) { await web.click(dismiss) } else { await web.press(.escape) }
        try? await web.sleep(0.8)
        let confirmButton = #"button[data-control-name="discard_application_confirm_btn"]"#
        if await web.exists(confirmButton) {
            await web.click(confirmButton)
        } else {
            // The confirmation, not the Easy Apply dialog itself (in Spanish its close button is also "Descartar").
            for root in ["[role=alertdialog]", #"[role=dialog]:not([data-auto-root="easy-apply"])"#]
            where await web.findButton(#"^(discard|descartar)$"#, root: root) != nil {
                await web.clickFoundButton()
                break
            }
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
        // A company's own careers page (…?gh_jid=123): the form is in a frame from Greenhouse, which the app can't
        // reach into from the page, or not drawn until Apply is pressed. Greenhouse's own page for it instead.
        if root == nil, let url = web.url, !(url.host ?? "").lowercased().hasSuffix("greenhouse.io"), let own = await Self.formPage(web, url) {
            Log.info("Opening Greenhouse's own page for the form: \(own.absoluteString)")
            try await web.load(own)
            _ = await web.waitFor(Self.formSelectors.joined(separator: ", "), timeout: 12)
            await web.dismissBanners()
            root = await formRoot()
        }
        if root == nil {
            try await clickApplyEntry()
            try await web.sleep(1.5)
            root = await formRoot()
        }
        guard let root else { return await failure("Couldn't find the Greenhouse application form.") }
        return try await runFormFlow(root: root)
    }

    /// Where a careers page's Greenhouse form lives: its Greenhouse frame (waited for a moment: it's added by a
    /// script), else Greenhouse's page for the job number, which finds the company's board itself
    /// (boards.greenhouse.io/embed/job_app?token=123 → job-boards.greenhouse.io/embed/job_app?for=stripe&token=123).
    static func formPage(_ web: WebAgent, _ url: URL) async -> URL? {
        for _ in 0..<4 {
            let src = await web.string(#"""
                const f = [...document.querySelectorAll('iframe')].find(f => /^https:\/\/[a-z0-9.-]*greenhouse\.io\/.*job_app/i.test(f.src || ''));
                return f ? f.src : '';
                """#)
            if let u = URL(string: src), !src.isEmpty { return u }
            try? await web.sleep(1)
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let jid = query.first(where: { $0.name == "gh_jid" })?.value, Regex(#"^\d{4,}$"#).matches(jid) else { return nil }
        var c = URLComponents(string: "https://boards.greenhouse.io/embed/job_app")!
        c.queryItems = [URLQueryItem(name: "token", value: jid)]
        if let src = query.first(where: { $0.name == "gh_src" })?.value, !src.isEmpty { c.queryItems?.append(URLQueryItem(name: "gh_src", value: src)) }
        return c.url
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
        // A careers page that embeds the whole job board (Tillster): find this job on it first.
        // (The board's name as the links spell it: "Alpaca%20Research", not "Alpaca Research".)
        if let url = web.url, let board = url.path(percentEncoded: true).split(separator: "/").first.map(String.init),
           url.path.split(separator: "/").count == 1 {
            _ = await web.waitFor("a[href*='/\(board)/'], a[href*='ashby_jid=']", timeout: 10)
            let posts = ((try? await web.js(Scripts.prelude + """
                // Links to the job on Ashby, or (the board embedded in a careers page) to "careers?ashby_jid=<id>".
                const id = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;
                const at = new RegExp('^' + id.source, 'i'), embedded = new RegExp('[?&]ashby_jid=' + id.source, 'i');
                const own = h => { const i = h.toLowerCase().indexOf(('/' + board + '/').toLowerCase()); return i >= 0 && at.test(h.slice(i + board.length + 2)); };
                return [...document.querySelectorAll('a[href]')].filter(a => own(a.href) || embedded.test(a.href)).map(a => {
                  const h = a.querySelector('h1, h2, h3, h4, [class*=title i]');
                  const href = own(a.href) ? a.href : 'https://jobs.ashbyhq.com/' + board + '/' + a.href.match(id)[0];
                  return [clean(h ? h.innerText : a.innerText.split('\\n')[0]), href, clean(a.innerText)];
                });
                """, ["board": board])) as? [[String]]) ?? []
            guard let i = Self.sameTitle(ctx.job.title, posts.map { $0.first ?? "" }, details: posts.map { $0.count > 2 ? $0[2] : "" },
                                         location: ctx.job.location), posts[i].count > 1, let link = URL(string: posts[i][1]) else {
                return await failure("The job isn't on the company's Ashby job board (\(posts.count) other jobs there).")
            }
            ctx.step("Found the job on the company's job board")
            try await web.load(link)
        }
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
            // A posting taken down: Ashby shows "Page not found" at its address.
            if Regex(#"\bpage not found\b|page you requested was not found|job (is )?no longer (available|open)"#).matches(norm(await web.text(maxChars: 600))) {
                return await failure("The job is no longer on the company's Ashby job board.")
            }
            return await failure("Couldn't find the Ashby application form.")
        }
        return try await runFormFlow(root: nil)
    }

    /// Which of a job board's postings is the job: the same title (else the only one with the job's title inside
    /// it, "Senior Engineer" in "Senior Engineer - Remote"); among postings of the same title, the one in the job's
    /// city. Nil when none fits.
    static func sameTitle(_ want: String, _ titles: [String], details: [String] = [], location: String = "") -> Int? {
        let w = norm(want).filter { $0.isLetter || $0.isNumber }
        guard !w.isEmpty else { return nil }
        let keys = titles.map { norm($0).filter { $0.isLetter || $0.isNumber } }
        var found = keys.indices.filter { keys[$0] == w }
        if found.isEmpty {
            let inside = keys.indices.filter { !keys[$0].isEmpty && (keys[$0].contains(w) || (keys[$0].count >= 8 && w.contains(keys[$0]))) }
            found = Set(inside.map { keys[$0] }).count == 1 ? inside : []
        }
        guard let first = found.first else { return nil }
        let places = location.split(separator: ",").map { norm(String($0)).trimmed }.filter { $0.count >= 3 && $0 != "united states" }
        return found.first { i in i < details.count && places.contains { norm(details[i]).contains($0) } } ?? first
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
                         aid("dateSectionMonth-input"), aid("dateSectionDay-input"), aid("dateSectionYear-input"),
                         aid("currentlyWorkHere"), aid("countryDropdown"), aid("phone-number")]
    }
    static let nextButton = "\(aid("bottom-navigation-next-button")), \(aid("pageFooterNextButton"))"
    static let success = Regex(#"application (has been )?submitted|congratulations|thank you for applying"#)
    static let verifyPrompt = Regex(#"verify your (email|account)|verification email|check your email|account (has not been|isn't) verified"#)
    /// A posting Workday has taken down.
    static let gone = Regex(#"page you are looking for (doesn'?t|does not) exist|(job|posting|requisition) (is )?no longer (available|accepting)|this job (posting )?(has )?(expired|closed)"#)

    private func visible(_ name: String) async -> Bool { await web.isVisible(Self.aid(name)) }

    /// Anything Workday shows once a page has drawn: the start choices, a sign-in box, or the wizard's buttons.
    static let ready = ["adventureButton", "autofillWithResume", "applyManually", "email", "signInLink", "createAccountLink", "SignInWithEmailButton",
                        "bottom-navigation-next-button", "pageFooterNextButton"].map(aid).joined(separator: ", ")

    /// What pressing the job page's Apply opens: the start choices, a sign-in box, or the form itself.
    static let afterApply = ["autofillWithResume", "applyManually", "useMyLastApplication", "email", "signInLink", "createAccountLink",
                             "SignInWithEmailButton", "bottom-navigation-next-button", "pageFooterNextButton"].map(aid).joined(separator: ", ")

    /// Workday draws each page with scripts after it loads: wait for it (up to `timeout`) before reading it.
    private func waitForPage(timeout: TimeInterval = 15) async throws {
        _ = await web.waitFor(Self.ready, visible: true, timeout: timeout)
        try await web.sleep(0.8)
        await web.dismissBanners()
    }

    override func apply() async throws -> ApplyResult {
        applicationURL = web.url
        try await web.sleep(1.5)
        try await waitForPage()
        if !(await web.exists(Self.ready)), Self.gone.matches(await web.text(maxChars: 1500)) {
            return await failure("The job is no longer on the company's Workday site.")
        }
        // A job Workday has taken down opens the site's job search instead (…/External_Career_Site, no /job/).
        if let path = web.url?.path, !path.contains("/job/"), !(await web.exists(Self.ready)), await web.exists(Self.aid("jobResults")) || !path.contains("/apply") {
            return await failure("The job is no longer on the company's Workday site (its link opens the site's job search).")
        }
        // Closing a cookie banner can redraw the job page (Nike's): its Apply button may be back a moment later.
        if !(await web.isVisible(Self.afterApply)) { _ = await web.waitFor(Self.ready, visible: true, timeout: 5) }
        try await pressApply()
        var usedAutofill = try await chooseStart()
        try await waitForPage()
        if let gate = try await signIn() { return gate }
        let autofillOffered = await visible("autofillWithResume")
        if usedAutofill || autofillOffered {
            let chose = try await chooseStart()
            usedAutofill = chose || usedAutofill
            await uploadResume()
        }
        var refused = 0
        for _ in 0..<ctx.limits.maxFormSteps {
            try Task.checkCancellation()
            try await waitIdle()
            await web.dismissBanners()
            if Self.success.matches(await web.text()) {
                return ApplyResult(.applied, notes: "Sent through Workday", evidence: await saveEvidence("Sent"), externalURL: web.url?.absoluteString)
            }
            var label = ""
            for _ in 0..<20 {
                label = await web.string(Scripts.prelude + "const b = [...document.querySelectorAll(sel)].find(shown); return b ? clean(b.innerText) : '';",
                                         ["sel": Self.nextButton])
                if !label.isEmpty { break }
                // Signed out partway (or the account page came back): sign in again, then look again.
                let email = await visible("email"), link = await visible("signInLink"), choices = await visible("SignInWithEmailButton")
                if email || link || choices {
                    if let gate = try await signIn() { return gate }
                }
                // Still on the job page (its Apply wasn't there to press yet): press it now and start again.
                if try await pressApply() {
                    if try await chooseStart() { usedAutofill = true; await uploadResume() }
                    if let gate = try await signIn() { return gate }
                }
                try await web.sleep(0.75)
            }
            guard !label.isEmpty else {
                let shown = await web.string(Scripts.prelude + "return [...document.querySelectorAll('[data-automation-id]')].filter(shown).map(e => e.dataset.automationId).filter((v, i, a) => a.indexOf(v) === i).slice(0, 30).join(' ');")
                Log.info("Workday: no Next or Submit; the page shows \(shown)")
                return await failure("Workday: no Next or Submit button on this page.")
            }
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
            await fixContactDetails()
            await fillExperience()
            await attachResumeIfAsked()
            let outcome = try await fillStep(root: nil)
            if let stop = outcome.stop { return stop }
            if let blocked = outcome.blocked { return needsAnswer(blocked) }
            let (advanced, result) = try await clickAndValidate(root: nil) {
                await web.bool(Scripts.prelude + "document.querySelectorAll('[data-auto-btn]').forEach(b => b.removeAttribute('data-auto-btn'));" +
                               "const b = [...document.querySelectorAll(sel)].find(shown); if (b) b.setAttribute('data-auto-btn', '1'); return !!b;",
                               ["sel": Self.nextButton])
            }
            if !advanced { return result! }
            // Boxes the form filler doesn't handle (dates, school search, the resume) show their errors only as text.
            try await web.sleep(1)
            let empty = await emptyRequired()
            if !empty.isEmpty {
                Log.info("Workday says these are empty: \(empty.prefix(4))")
                refused += 1
                if refused >= 3 { return await failure("Workday didn't accept the page; still empty: \(empty.prefix(4).joined(separator: ", "))") }
                continue
            }
            refused = 0
            ctx.step("Next page of the form")
            try await stepPause()
        }
        return await failure("Workday: went past \(ctx.limits.maxFormSteps) pages.")
    }

    private func waitIdle() async throws {
        for _ in 0..<32 where web.webView.isLoading { try await web.sleep(0.25) }
        try await web.sleep(0.8)
    }

    /// Presses the job page's Apply, if it shows, and waits for what it opens. True if it was pressed.
    @discardableResult
    private func pressApply() async throws -> Bool {
        guard await visible("adventureButton"), !(await web.isVisible(Self.afterApply)) else { return false }
        Log.info("Workday: pressing the job page's Apply")
        await web.click(Self.aid("adventureButton"))
        try await web.sleep(2)
        // The start choices open in a popup over the job page, whose Apply button still counts as "ready".
        _ = await web.waitFor(Self.afterApply, visible: true, timeout: 10)
        try await waitForPage()
        return true
    }

    /// Prefers "Autofill with Resume", else "Apply Manually". True if autofill was chosen.
    private func chooseStart() async throws -> Bool {
        for (name, autofill) in [("autofillWithResume", true), ("applyManually", false)] where await visible(name) {
            Log.info("Workday: starting with \(name)")
            await web.click(Self.aid(name))
            try await web.sleep(2.5)
            return autofill
        }
        return false
    }

    /// Workday covers its buttons with a "click_filter" (role=button) that takes the click; the button under it is
    /// hidden from people. Older pages put the filter inside the button, newer ones just before it.
    private func pressSubmit(_ name: String) async {
        let button = Self.aid(name), filter = Self.aid("click_filter")
        for overlay in ["\(button) \(filter)", "\(filter):has(+ \(button))", "\(button) + \(filter)"] where await web.isVisible(overlay) {
            await web.click(overlay)
            return
        }
        await web.click(button)
    }

    /// Newer sign-in pages offer Apple, Google or "Sign in with email" first; the email form is behind the last.
    private func revealEmailForm() async throws {
        guard !(await visible("email")), await visible("SignInWithEmailButton") else { return }
        await web.click(Self.aid("SignInWithEmailButton"))
        try await web.sleep(1.5)
        _ = await web.waitFor(Self.aid("email"), visible: true, timeout: 8)
    }

    private func signIn() async throws -> ApplyResult? {
        try await revealEmailForm()
        let signInLink = await visible("signInLink"), createLink = await visible("createAccountLink")
        if !(await visible("email")), signInLink || createLink {
            await web.click(Self.aid(signInLink ? "signInLink" : "createAccountLink"))
            try await web.sleep(1.5)
            _ = await web.waitFor(Self.aid("email"), visible: true, timeout: 8)
        }
        guard await visible("email") else { return nil }
        let password = ctx.secrets.portalPassword
        guard !password.isEmpty else { return await failure("Workday needs an account, but no portal password is set (Settings › Accounts).") }
        let email = ctx.profile.personal.email
        let host = web.url?.host ?? ""
        if !(await visible("verifyPassword")) {
            if try await trySignIn(email, password) {
                ctx.db.noteAccount(host: host, email: email, how: .signedIn)
                return nil
            }
            switch try await confirmUnverified(email, password) {
            case .signedIn: return nil
            case .stop(let result): return result
            case .notThat: break
            }
            // An account the app made (or reset) here whose password no longer works.
            if ctx.db.hasAccount(host: host) || resetTried { return try await resetPassword(email, password) }
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
            if accountExists.matches(msg) { return try await resetPassword(email, password) }
            return await failure("Workday didn't create the account: \(msg.prefix(200))")
        }
        let pageText = await web.text()
        if await visible("verifyPassword"), !Self.verifyPrompt.matches(pageText) {
            // Still the sign-up form: no account, so no email is coming.
            return await failure("Workday didn't create the account: pressing Create Account did nothing.")
        }
        let emailBox = await visible("email"), signInShown = await visible("signInLink")
        if !emailBox && !signInShown {
            // Signed in already, or a page that only says to check the email.
            ctx.db.noteAccount(host: host, email: email, how: .made)
            if Self.verifyPrompt.matches(pageText), let res = try await verifyEmail(since: createdAt) { return res }
            return nil
        }
        // Workday answers Create Account the same way whether or not the email already had an account. Signing in
        // once tells them apart: a new account asks to confirm its email; one that was already there (made by hand,
        // with another password) says the password is wrong.
        if try await trySignIn(email, password) {
            ctx.db.noteAccount(host: host, email: email, how: .made)
            return nil
        }
        if await unverifiedShown() {
            ctx.db.noteAccount(host: host, email: email, how: .made)
            if let res = try await verifyEmail(since: createdAt) { return res }
            if try await trySignIn(email, password) { return nil }
            switch try await confirmUnverified(email, password) {
            case .signedIn: return nil
            case .stop(let result): return result
            case .notThat: return await failure("Workday: couldn't sign in after creating the account.")
            }
        }
        return try await resetPassword(email, password)
    }

    /// Workday's sign-in box saying the account's email was never confirmed (with a button to send the link again).
    private func unverifiedShown() async -> Bool {
        guard Self.verifyPrompt.matches(await web.text(maxChars: 3000)) else { return false }
        return await web.findButton(Self.resendPattern) != nil
    }
    static let resendPattern = #"^resend( account)? verification( e-?mail| link)?$"#

    /// The email already has an account on this Workday site whose password isn't the portal password (made by
    /// hand, or before): "Forgot your password?", the link from Workday's email, the portal password as the new
    /// one, then signs in. Returns a result to stop with, or nil once signed in.
    private func resetPassword(_ email: String, _ password: String) async throws -> ApplyResult? {
        guard !resetTried else { return await failure("Workday: couldn't sign in even after resetting the password to your portal password.") }
        resetTried = true
        guard ctx.verifier.configured else {
            return await failure("\(ctx.company)'s Workday site already has an account for your email, with another password. The app resets it to "
                                 + "your portal password through Workday's reset email, but email isn't connected (Settings › Email codes).", .failedOTPTimeout)
        }
        let back = web.url
        if !(await visible("forgotPasswordLink")), await visible("signInLink") {
            await web.click(Self.aid("signInLink"))
            try await web.sleep(1.5)
        }
        guard await visible("forgotPasswordLink") else {
            return await failure("\(ctx.company)'s Workday site already has an account for your email, with another password, and shows no "
                                 + "“Forgot your password?” link. Reset it there to your portal password (Settings › Company-site accounts).")
        }
        ctx.step("\(ctx.company)'s Workday site already has an account for your email: resetting its password to your portal password")
        await web.click(Self.aid("forgotPasswordLink"))
        try await web.sleep(1.5)
        _ = await web.waitFor(Self.aid("resetPasswordButton"), visible: true, timeout: 8)
        await web.fill(Self.aid("email"), email)
        let since = Date()
        await pressSubmit("resetPasswordButton")
        try await web.sleep(3)
        ctx.step("Waiting for Workday's password reset email")
        let wait = max(ctx.limits.otpTimeoutSec, 240)
        guard let res = await ctx.verifier.waitForVerification(senderHint: "workday|myworkday|" + emailHint, since: since.addingTimeInterval(-30),
                                                               timeout: TimeInterval(wait), kind: .reset),
              let link = res.url, let url = URL(string: link) else {
            return await failure("Workday's password reset email didn't arrive within \(wait / 60) minutes.", .failedOTPTimeout)
        }
        ctx.step("Opening the reset link from Workday's email")
        try await web.load(url)
        try await web.sleep(2)
        _ = await web.waitFor("input[type=password]", visible: true, timeout: 12)
        if await visible("email"), (await web.string(#"return (document.querySelector(sel) || {}).value || '';"#, ["sel": Self.aid("email")])).isEmpty {
            await web.fill(Self.aid("email"), email)
        }
        guard await web.fillPasswords(password) > 0 else {
            return await failure("Workday's password reset page had no box for the new password.")
        }
        ctx.step("Setting your portal password as the new password")
        if await web.isVisible(Self.aid("click_filter")) {
            await web.click(Self.aid("click_filter"))
        } else if await web.hasButton(setPasswordPattern) {
            await web.clickFoundButton()
        } else {
            await web.press(.enter)
        }
        try await web.sleep(4)
        let errors = await web.collectErrors()
        let errorShown = await visible("errorMessage")
        if await web.hasPasswordField(), !errors.isEmpty || errorShown {
            let msg = errors.isEmpty ? String(await web.text(maxChars: 300)) : errors.values.joined(separator: "; ")
            return await failure("Workday didn't take your portal password as the new password: \(msg.prefix(200))")
        }
        if let host = back?.host { ctx.db.noteAccount(host: host, email: email, how: .reset) }
        ctx.step("Reset the password on \(ctx.company)'s Workday site to your portal password")
        if let back { try await web.load(back) }
        try await web.sleep(2.5)
        try await waitForPage(timeout: 10)
        let emailAgain = await visible("email"), linkAgain = await visible("signInLink")
        if emailAgain || linkAgain {
            if try await trySignIn(email, password) { return nil }
            return await failure("Workday: couldn't sign in after resetting the password to your portal password.")
        }
        return nil
    }

    private func trySignIn(_ email: String, _ password: String) async throws -> Bool {
        if await visible("signInLink") {
            await web.click(Self.aid("signInLink"))
            try await web.sleep(1.2)
        }
        try await revealEmailForm()
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

    private enum Unverified { case notThat, signedIn, stop(ApplyResult) }

    /// Workday won't sign in to an account whose email was never confirmed ("Verify your account before you sign in")
    /// and offers to send the link again: asks for it, opens it from the inbox, and signs in.
    private func confirmUnverified(_ email: String, _ password: String) async throws -> Unverified {
        guard Self.verifyPrompt.matches(await web.text(maxChars: 3000)), await web.findButton(Self.resendPattern) != nil else { return .notThat }
        ctx.step("Asking Workday to send the verification email again")
        let since = Date()
        await web.clickFoundButton()
        try await web.sleep(3)
        if let res = try await verifyEmail(since: since) { return .stop(res) }
        if try await trySignIn(email, password) { return .signedIn }
        return .stop(await failure("Workday: couldn't sign in after confirming the account's email."))
    }

    private func verifyEmail(since: Date) async throws -> ApplyResult? {
        guard ctx.verifier.configured else {
            return await failure("Workday sent a verification email, but email isn't connected (Settings › Email codes).", .failedOTPTimeout)
        }
        ctx.step("Waiting for Workday's verification email")
        // Workday's emails can take a few minutes.
        let wait = max(ctx.limits.otpTimeoutSec, 240)
        guard let res = await ctx.verifier.waitForVerification(senderHint: "workday|myworkday|" + emailHint, since: since,
                                                               timeout: TimeInterval(wait), kind: .link),
              let link = res.url, let url = URL(string: link) else {
            return await failure("Workday's verification email didn't arrive within \(wait / 60) minutes.", .failedOTPTimeout)
        }
        let back = web.url
        ctx.step("Opening the verification link from Workday's email")
        try await web.load(url)
        try await web.sleep(2)
        try await waitForPage(timeout: 10)
        if let back { try await web.load(back) }
        try await web.sleep(2.5)
        return nil
    }

    /// A page that asks for the resume (a "Resume/CV" section's "Upload a file") when none is attached yet. Another
    /// upload (a cover letter) is left alone.
    private func attachResumeIfAsked() async {
        let wanted = await web.bool(Scripts.prelude + """
            const input = document.querySelector(sel); if (!input) return false;
            const f = input.closest('[data-automation-id^="formField"]') || input.parentElement;
            const area = f.parentElement || f;
            if (area.querySelector('[data-automation-id="delete-file"], [data-automation-id="file-upload-successful"]')) return false;
            const heads = [...document.querySelectorAll('h1, h2, h3, h4, h5, h6, [role=heading]')]
              .filter(h => shown(h) && (h.compareDocumentPosition(input) & Node.DOCUMENT_POSITION_FOLLOWING));
            const label = f.querySelector('label, legend');
            const near = (heads.length ? heads[heads.length - 1].innerText : '') + ' ' + (label ? label.innerText : '');
            return /resume|\\bcv\\b|curriculum/i.test(near);
            """, ["sel": Self.aid("file-upload-input-ref")])
        if wanted { await uploadResume() }
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

    /// "My Information": Workday's Country list, "Country Phone Code" search and phone number, which it may fill from
    /// the resume or an old account (Dexcom and Caterpillar: "Peru", "Peru (+51)" and "+1 5125550142", then "Enter a
    /// valid format for Phone Number"). Set from the profile: its country, its phone code, the number without the code.
    private func fixContactDetails() async {
        let p = ctx.profile.personal
        let country = p.address.country.trimmed
        guard !country.isEmpty else { return }
        let code = p.phoneCountryCode.filter(\.isNumber)
        let state = (try? await web.js(Self.contactBoxes, ["code": code])) as? [String: Any] ?? [:]
        // The country list.
        if let shown = state["country"] as? String, !Self.sameCountry(shown, country) {
            await web.click(#"[data-auto-wd="country"]"#)
            try? await web.sleep(1)
            var options = ((try? await web.js(Scripts.options, ["sel": #"[data-auto-wd="country"]"#])) as? [String]) ?? []
            if !options.contains(where: { Self.sameCountry($0, country) }),
               await web.bool(Scripts.scrollToOption, ["sel": #"[data-auto-wd="country"]"#, "want": Self.countryNames(country)]) {
                options = ((try? await web.js(Scripts.options, ["sel": #"[data-auto-wd="country"]"#])) as? [String]) ?? []
            }
            if let i = options.firstIndex(where: { Self.sameCountry($0, country) }) {
                await web.click(#"[data-auto-choice="\#(i)"]"#)
                ctx.step("Set the country to \(options[i]) (the site had \(shown))")
                try? await web.sleep(2)  // the address boxes change with the country
            } else {
                await web.press(.escape)
            }
        }
        // The phone code: a search, like "How did you hear about us?".
        if let shown = state["phoneCode"] as? String, !code.isEmpty, !shown.contains("(+\(code))") {
            await web.click(#"[data-auto-wd="phoneCode"]"#)
            await web.fill(#"[data-auto-wd="phoneCode"]"#, Self.countryNames(country).first ?? country, keepFocus: true)
            await web.press(.enter)
            try? await web.sleep(1.5)
            let options = ((try? await web.js(Scripts.prelude + "return [...document.querySelectorAll(sel)].filter(shown).map(o => clean(o.innerText));",
                                              ["sel": Self.aid("promptOption")])) as? [String]) ?? []
            if let i = options.firstIndex(where: { $0.contains("(+\(code))") && Self.sameCountry($0.replacingOccurrences(of: #"\s*\(\+\d+\)$"#, with: "", options: .regularExpression), country) }) {
                await web.bool(Scripts.prelude + "document.querySelectorAll('[data-auto-pick]').forEach(e => e.removeAttribute('data-auto-pick'));" +
                               "const o = [...document.querySelectorAll(sel)].filter(shown)[i]; if (o) o.setAttribute('data-auto-pick', '1'); return !!o;",
                               ["sel": Self.aid("promptOption"), "i": i])
                await web.click(#"[data-auto-pick="1"]"#)
                ctx.step("Set the phone's country code to \(options[i])")
                try? await web.sleep(0.8)
            } else {
                await web.press(.escape)
            }
        }
        // The number without the country code in front of it.
        if let shown = state["phone"] as? String {
            let mine = Self.nationalNumber(p.phone, code: code)
            if !mine.isEmpty, shown.filter(\.isNumber) != mine {
                await web.fill(#"[data-auto-wd="phone"]"#, mine)
                ctx.step(shown.isEmpty ? "Entered your phone number" : "Entered your phone number without the country code")
            }
        }
    }

    /// Tags Workday's country list (data-auto-wd="country"), phone code search ("phoneCode") and phone number
    /// ("phone"), and returns what each shows.
    static let contactBoxes = Scripts.prelude + #"""
    document.querySelectorAll('[data-auto-wd]').forEach(e => e.removeAttribute('data-auto-wd'));
    const out = {};
    const named = re => [...document.querySelectorAll('[data-automation-id^="formField"]')].filter(shown).find(f => {
      const l = f.querySelector('label, legend'); return l && re.test(clean(l.innerText).replace(/\s*\*$/, ''));
    });
    const c = document.querySelector('[data-automation-id="countryDropdown"]') || (named(/^country$/i) || document.createElement('i')).querySelector('button[aria-haspopup]');
    if (c && shown(c)) { c.setAttribute('data-auto-wd', 'country'); out.country = clean(c.innerText); }
    const pc = document.querySelector('[data-automation-id="countryPhoneCode"]') || named(/^country phone code$/i);
    if (pc) {
      const box = pc.querySelector('[data-automation-id="multiselectInputContainer"] input, input[data-automation-id="searchBox"], input');
      const picked = pc.querySelector('[data-automation-id="selectedItem"]');
      if (box) { box.setAttribute('data-auto-wd', 'phoneCode'); out.phoneCode = picked ? clean(picked.innerText) : ''; }
    }
    const ph = document.querySelector('input[data-automation-id="phone-number"]') || (named(/^phone number$/i) || document.createElement('i')).querySelector('input');
    if (ph && shown(ph)) { ph.setAttribute('data-auto-wd', 'phone'); out.phone = ph.value || ''; }
    return out;
    """#

    /// The ways a country is written in lists: "United States" is also "United States of America", "USA".
    static func countryNames(_ country: String) -> [String] {
        let n = norm(country)
        if Regex(#"^(united states( of america)?|u\.?s\.?(a\.?)?|america)$"#).matches(n) { return ["United States of America", "United States", "USA"] }
        if Regex(#"^(united kingdom|uk|great britain)$"#).matches(n) { return ["United Kingdom", "UK"] }
        return [country]
    }

    static func sameCountry(_ shown: String, _ country: String) -> Bool {
        let key = { (t: String) in t.lowercased().filter { $0.isLetter || $0.isNumber } }
        return countryNames(country).contains { key($0) == key(shown) }
    }

    /// The phone number as it is dialled within its country: "+1 (512) 555-0142" → "5125550142".
    static func nationalNumber(_ phone: String, code: String) -> String {
        var d = phone.filter(\.isNumber)
        if !code.isEmpty, phone.trimmed.hasPrefix("+") || d.count > 10, d.hasPrefix(code) { d.removeFirst(code.count) }
        return d
    }

    /// "My Experience": Workday reads the jobs and schools off the resume, but can leave a job's From or To date or a
    /// school empty, and those boxes (month/year spinners, the school search) aren't ones the form filler handles.
    /// Fills them from the profile's matching job or school; a job or school the profile doesn't have is left alone.
    private func fillExperience() async {
        guard let panels = (try? await web.js(Self.experiencePanels)) as? [[String: Any]], !panels.isEmpty else { return }
        for p in panels {
            let i = (p["i"] as? NSNumber)?.intValue ?? 0
            func s(_ key: String) -> String { ((p[key] as? String) ?? "").trimmed }
            func has(_ key: String) -> Bool { (p[key] as? Bool) == true }
            if s("kind") == "work" {
                guard let role = Self.matchRole(ctx.profile.workHistory, company: s("company"), title: s("title"), fromYear: s("fromY")) else { continue }
                if has("hasFrom"), s("fromY").isEmpty, let d = Self.monthYear(role.startDate) {
                    await fillDate(i, "from", d)
                    ctx.step("Entered when you started at \(role.company)")
                }
                if has("hasTo"), s("toY").isEmpty, !has("current") {
                    if role.isCurrent, p["current"] is Bool {
                        await web.click(#"[data-auto-wd="\#(i)-current"]"#)
                        ctx.step("Ticked “I currently work here” for \(role.company)")
                    } else if !role.isCurrent, let d = Self.monthYear(role.endDate) {
                        await fillDate(i, "to", d)
                        ctx.step("Entered when you left \(role.company)")
                    }
                }
            } else if s("kind") == "education", has("schoolBox"), s("school").isEmpty,
                      let school = Self.matchSchool(ctx.profile.education, degree: s("degree"), study: s("study")) {
                await pickSchool(i, school.school)
            }
        }
        try? await web.sleep(0.5)
    }

    private func fillDate(_ panel: Int, _ which: String, _ date: (month: String?, year: String)) async {
        if let month = date.month, await web.exists(#"[data-auto-wd="\#(panel)-\#(which)M"]"#) {
            await web.click(#"[data-auto-wd="\#(panel)-\#(which)M"]"#)
            await web.fill(#"[data-auto-wd="\#(panel)-\#(which)M"]"#, month)
        }
        if await web.exists(#"[data-auto-wd="\#(panel)-\#(which)Y"]"#) {
            await web.fill(#"[data-auto-wd="\#(panel)-\#(which)Y"]"#, date.year)
        }
    }

    /// The school box is a search: type the name, press Enter, pick it from the list; Workday asks for "Other" when
    /// the school isn't in its list.
    private func pickSchool(_ panel: Int, _ name: String) async {
        let box = #"[data-auto-wd="\#(panel)-school"]"#
        for typed in [name, "Other"] {
            await web.click(box)
            await web.fill(box, typed, keepFocus: true)
            await web.press(.enter)
            try? await web.sleep(1.5)
            let options = ((try? await web.js(Scripts.prelude + "return [...document.querySelectorAll(sel)].filter(shown).map(o => clean(o.innerText));",
                                              ["sel": Self.aid("promptOption")])) as? [String]) ?? []
            let choice = typed == "Other" ? options.first { norm($0) == "other" } : Self.closestSchool(name, options)
            if let choice, let idx = options.firstIndex(of: choice) {
                await web.bool(Scripts.prelude + "document.querySelectorAll('[data-auto-pick]').forEach(e => e.removeAttribute('data-auto-pick'));" +
                               "const o = [...document.querySelectorAll(sel)].filter(shown)[i]; if (o) o.setAttribute('data-auto-pick', '1'); return !!o;",
                               ["sel": Self.aid("promptOption"), "i": idx])
                await web.click(#"[data-auto-pick="1"]"#)
                try? await web.sleep(0.8)
                ctx.step(typed == "Other" ? "Chose “Other” for \(name) (it isn't in the site's list of schools)" : "Chose your school, \(choice)")
                return
            }
            await web.press(.escape, selector: box)
            try? await web.sleep(0.3)
        }
    }

    /// The profile's job that a job Workday read off the resume is: same company, and the same start year or title
    /// when the profile has several there. Nil when none fits.
    static func matchRole(_ roles: [Role], company: String, title: String, fromYear: String) -> Role? {
        var found = roles.filter { !$0.company.trimmed.isEmpty && sameName($0.company, company) }
        if !fromYear.isEmpty {
            found = found.filter { r in monthYear(r.startDate).map { $0.year == fromYear } ?? true }
        }
        if found.count > 1, let byTitle = found.first(where: { sameName($0.title, title) }) { return byTitle }
        return found.count == 1 ? found[0] : nil
    }

    /// The profile's school for a Workday education panel: the one with the same kind of degree (and field of study,
    /// when that's needed to tell two apart).
    static func matchSchool(_ schools: [Education], degree: String, study: String) -> Education? {
        let named = schools.filter { !$0.school.trimmed.isEmpty }
        if named.count == 1, degree.isEmpty { return named[0] }
        let level = ProfileRules.degreeLevel(degree)
        var found = level == 0 ? named : named.filter { ProfileRules.degreeLevel($0.degree) == level }
        if found.count > 1, !study.isEmpty { found = found.filter { sameName($0.fieldOfStudy, study) } }
        return found.count == 1 ? found[0] : nil
    }

    /// The option in Workday's school list that is the school: its words all in the name, or the name's all in it.
    static func closestSchool(_ name: String, _ options: [String]) -> String? {
        func words(_ s: String) -> Set<String> {
            let stop: Set<String> = ["of", "the", "at", "and", "in"]
            let t = s.lowercased().replacingOccurrences(of: "[’']", with: "", options: .regularExpression)
            return Set(t.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty && !stop.contains($0) }
                .map { $0 == "saint" ? "st" : $0 })
        }
        let want = words(name)
        guard !want.isEmpty else { return nil }
        let fits = options.compactMap { o -> (String, Double)? in
            let have = words(o)
            guard !have.isEmpty, have.isSubset(of: want) || want.isSubset(of: have) else { return nil }
            return (o, Double(have.intersection(want).count) / Double(have.union(want).count))
        }
        return fits.max { $0.1 < $1.1 }?.0
    }

    /// Same company or title: the same letters and digits, or one inside the other.
    static func sameName(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased().filter { $0.isLetter || $0.isNumber }, y = b.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x == y || (min(x.count, y.count) >= 4 && (x.contains(y) || y.contains(x)))
    }

    /// "2022" → (nil, "2022"); "Jan 2023", "2023-01", "01/2023" → ("01", "2023"). Nil without a year. A month the
    /// profile doesn't give is entered as January, as Workday does with a year read off the resume.
    static func monthYear(_ text: String) -> (month: String?, year: String)? {
        let t = text.lowercased()
        guard let year = Regex(#"\b(19|20)\d{2}\b"#).allMatches(t).first else { return nil }
        let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        var month: Int?
        if let i = names.firstIndex(where: { Regex(#"\b\#($0)"#).matches(t) }) { month = i + 1 }
        else if let g = Regex(#"\b(\d{1,2})[/.-](19|20)\d{2}\b"#).firstGroups(t), g.count > 1, let m = g[1].flatMap(Int.init) { month = m }
        else if let g = Regex(#"\b(19|20)\d{2}[/.-](\d{1,2})\b"#).firstGroups(t), g.count > 2, let m = g[2].flatMap(Int.init) { month = m }
        if let m = month, !(1...12).contains(m) { month = nil }
        return (String(format: "%02d", month ?? 1), year)
    }

    /// Workday's message for a box left empty, on the page and in its "Errors Found" list.
    static let requiredMessage = Regex(#"The field (.{1,80}?) is required and must have a value"#)

    /// The boxes Workday says are still empty after pressing Next.
    private func emptyRequired() async -> [String] {
        var seen = Set<String>()
        return Self.requiredMessage.allMatches(await web.text(), group: 1).map(\.trimmed).filter { seen.insert($0).inserted }
    }

    /// The jobs and schools on "My Experience", each tagged data-auto-wd="<panel>-<part>": fromM/fromY/toM/toY (the
    /// date boxes), current ("I currently work here"), school (the school search).
    static let experiencePanels = Scripts.prelude + #"""
    document.querySelectorAll('[data-auto-wd]').forEach(e => e.removeAttribute('data-auto-wd'));
    const HEAD = 'h1, h2, h3, h4, h5, h6, [role=heading], legend';
    const heads = [...document.querySelectorAll(HEAD)].filter(h => shown(h) && /^(work experience|education) \d+$/i.test(clean(h.innerText)));
    const out = [];
    heads.forEach((h, i) => {
      const alone = p => p && heads.filter(x => p.contains(x)).length === 1;
      let panel = h.closest('[role=group]');
      if (!alone(panel)) {
        panel = h;
        while (panel.parentElement && panel.parentElement !== document.body && alone(panel.parentElement)) panel = panel.parentElement;
      }
      const field = re => {
        for (const l of panel.querySelectorAll('label, legend')) {
          if (!shown(l) || !re.test(clean(l.innerText).replace(/\s*\*$/, ''))) continue;
          return l.closest('[data-automation-id^="formField"]') || l.closest('fieldset') || l.parentElement;
        }
        return null;
      };
      // What a box shows: a list's choice (its hidden box holds an id), else what was typed.
      const text = f => {
        if (!f) return '';
        const picked = f.querySelector('[data-automation-id="selectedItem"], button[aria-haspopup]');
        if (picked && clean(picked.innerText)) return clean(picked.innerText).replace(/^select one$/i, '');
        const box = f.querySelector('input:not([type=checkbox]):not([type=hidden]):not([aria-hidden=true]), textarea');
        return box && box.value ? clean(box.value) : '';
      };
      const date = (f, part, tag) => {
        if (!f) return '';
        const e = f.querySelector(`[data-automation-id="dateSection${part}-input"]`) ||
          f.querySelector(part === 'Month' ? 'input[placeholder="MM" i], input[aria-label*="month" i]' : 'input[placeholder="YYYY" i], input[aria-label*="year" i]');
        if (!e) return '';
        e.setAttribute('data-auto-wd', `${i}-${tag}`);
        const v = clean(e.value || e.getAttribute('aria-valuetext') || '');
        return /\d/.test(v) ? v : '';
      };
      const r = { i, kind: /^education/i.test(clean(h.innerText)) ? 'education' : 'work' };
      if (r.kind === 'work') {
        r.company = text(field(/^company$/i)); r.title = text(field(/^job title$/i));
        const from = field(/^from$/i), to = field(/^to$/i);
        r.hasFrom = !!from; r.hasTo = !!to && shown(to);
        r.fromM = date(from, 'Month', 'fromM'); r.fromY = date(from, 'Year', 'fromY');
        r.toM = date(to, 'Month', 'toM'); r.toY = date(to, 'Year', 'toY');
        const cl = [...panel.querySelectorAll('label')].find(l => /currently work here/i.test(l.innerText));
        const cb = (cl && (cl.control || cl.querySelector('input[type=checkbox]') || (cl.parentElement && cl.parentElement.querySelector('input[type=checkbox]')))) ||
          panel.querySelector('[data-automation-id="currentlyWorkHere"]');
        if (cb) { cb.setAttribute('data-auto-wd', `${i}-current`); r.current = !!(cb.checked || cb.getAttribute('aria-checked') === 'true'); }
      } else {
        const school = field(/^(school|university|college)( or (university|college|school))?$/i);
        r.degree = text(field(/^degree$/i)); r.study = text(field(/^field of study$/i));
        if (school) {
          const picked = school.querySelector('[data-automation-id="selectedItem"]');
          const box = school.querySelector('[data-automation-id="multiselectInputContainer"] input, input[data-automation-id="searchBox"]');
          r.school = picked ? clean(picked.innerText) : '';
          if (box && !picked) { box.setAttribute('data-auto-wd', `${i}-school`); r.schoolBox = true; }
        }
      }
      out.push(r);
    });
    return out;
    """#

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
    /// The big sign-in services ("Sign in with Apple", Google, Microsoft…) a careers site may hand off to. The app
    /// never types anything there: the portal password is only for the careers sites themselves.
    public static func identityProvider(_ url: URL?) -> String? {
        guard let host = url?.host?.lowercased() else { return nil }
        let providers: [(String, [String])] = [
            ("Apple", ["apple.com", "icloud.com"]),
            ("Google", ["accounts.google.com", "google.com"]),
            ("Microsoft", ["microsoftonline.com", "login.live.com", "live.com", "login.microsoft.com", "account.microsoft.com"]),
            ("GitHub", ["github.com"]),
            ("LinkedIn", ["linkedin.com"]),
            ("Facebook", ["facebook.com"]),
            ("X", ["x.com", "twitter.com"]),
            ("Yahoo", ["yahoo.com"]),
            ("Amazon", ["amazon.com"]),
        ]
        for (name, domains) in providers where domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return name }
        return nil
    }

    /// Services that stand in front of a site to turn away automated browsers (Radware's "perfdrive", Imperva).
    static let botBlockers = ["perfdrive.com", "validate.perfdrive.com", "incapsula.com", "imperva.com"]

    /// Job boards that make you an account by swearing to something only you can (ClearanceJobs: a security clearance,
    /// "providing false information … is a felony"). The app doesn't make those accounts.
    static func sworeBoard(_ url: URL?) -> String? {
        guard let host = url?.host?.lowercased() else { return nil }
        if host == "clearancejobs.com" || host.hasSuffix(".clearancejobs.com") {
            return "The job is on ClearanceJobs, which asks you to make an account there and confirm your security clearance. Apply there yourself."
        }
        return nil
    }

    static func identityStop(_ name: String) -> String {
        "The company's site sends you to sign in with your \(name) account. The app never signs in to \(name) for you."
    }

    /// Careers sites that open in India's version wherever the job is: TCS's iBegin, whose India version asks for an
    /// Indian tax ID (PAN), a date of birth and an Aadhaar card. Returns the version for the job's country, or nil.
    public static func countryVersion(_ url: URL?, jobLocation: String) -> URL? {
        guard let url, let host = url.host?.lowercased(), host == "tcsapps.com" || host.hasSuffix(".tcsapps.com"),
              url.path.contains("/en-IN/"), let locale = locale(of: jobLocation), locale != "en-IN" else { return nil }
        return URL(string: url.absoluteString.replacingOccurrences(of: "/en-IN/", with: "/\(locale)/"))
    }

    /// "Raleigh, NC" → "en-US"; "Toronto, Ontario, Canada" → "en-CA"; nil when the place doesn't say.
    static func locale(of location: String) -> String? {
        let place = location.lowercased()
        if Regex(#"\bindia\b"#).matches(place) { return "en-IN" }
        if Regex(#"\bcanada\b"#).matches(place) { return "en-CA" }
        if Regex(#"\b(united states|usa|u\.s\.)"#).matches(place) { return "en-US" }
        // "City, ST" or "City, State", maybe with "(Hybrid)" after it.
        let parts = location.split(separator: ",").map { String($0).trimmed }
        guard parts.count >= 2 else { return nil }
        let region = parts[1].replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)
        if LinkedIn.usStates[region.uppercased()] != nil || LinkedIn.usStates.values.contains(where: { $0.caseInsensitiveCompare(region) == .orderedSame }) {
            return "en-US"
        }
        return nil
    }

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

    public enum Reach: Sendable {
        case ready(ATSType)
        case stop(String)
    }

    /// From wherever LinkedIn's Apply button landed to the application itself: closes cookie banners, waits out an
    /// automatic bot check, opens a form drawn in a frame, and follows "Apply now" / "I'm applying for the first time"
    /// / "Proceed" until a form (or a known applicant system) shows.
    @MainActor
    static func reachApplication(_ web: WebAgent, step: (String) -> Void) async throws -> Reach {
        var reloaded = false
        var pressed = Set<String>()
        for _ in 0..<6 {
            try Task.checkCancellation()
            if let idp = identityProvider(web.url) { return .stop(identityStop(idp)) }
            if let host = web.url?.host?.lowercased(), Self.botBlockers.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                return .stop("The company's site turns away automated browsers (\(host)). Apply on their site yourself.")
            }
            if let board = sworeBoard(web.url) { return .stop(board) }
            // The browser's own error page: the company's site didn't answer (Realsoft's, from LinkedIn's Apply).
            if web.url?.scheme == "chrome-error" {
                if !reloaded {
                    reloaded = true
                    try? await web.reload()
                    try await web.sleep(3)
                    if web.url?.scheme != "chrome-error" { continue }
                }
                return .stop("The company's site didn't load" + (web.lastNavigationError.map { " (\($0))" } ?? "")
                             + ". It may be down, or it turns away automated browsers. Try the job's link yourself.")
            }
            await web.dismissBanners()
            var page = await web.pageKind()
            if page.kind == .botcheck {
                step("Waiting for the site's security check")
                guard await web.waitOutBotCheck() else { return .stop(await web.botCheckNote("The company's site")) }
                try? await web.waitForLoad(timeout: 15)
                await web.dismissBanners()
                page = await web.pageKind()
            }
            let ats = web.url.map(detect) ?? .generic
            if ats != .generic { return .ready(ats) }
            // A job board that sends a gone job back to its list (CareerPuck's "?notFound=6123483004").
            if let q = web.url?.query, Regex(#"(^|&)(notfound|jobnotfound|job_not_found)=\w"#).matches(q.lowercased()) {
                return .stop("The company's site says this job is closed.")
            }
            switch page.kind {
            case .closed where page.fields == 0:
                return .stop("The company's site says this job is closed.")
            case .error where !reloaded:
                reloaded = true
                try? await web.reload()
                try await web.sleep(2)
                continue
            case .error where page.bare:
                // Nothing of the site's own around the message (Deloitte's “We could not process your request”).
                return .stop("The company's site wouldn't open in the app's browser; it showed only “\(page.text.prefix(100))”. "
                             + "Sites do this to turn away automated browsers. Apply on their site yourself.")
            case .error:
                return .stop("The company's site showed an error: “\(page.text.prefix(120))”")
            case .emaillink:
                return .ready(.generic)
            default:
                break
            }
            if let framed = try await openFramedForm(web, pageFields: page.fields) {
                if framed != .generic { return .ready(framed) }
                continue
            }
            if page.fields >= 3 || page.passwords > 0 { return .ready(.generic) }
            let before = "\(web.url?.absoluteString ?? "")#\(page.fields)#\(page.text)"
            var entry = try await web.followEntry(anyButton: page.fields == 0)
            // Careers sites often draw their Apply button a moment after the page (Phenom, Aurelia).
            for _ in 0..<4 where entry == nil && page.fields == 0 {
                try await web.sleep(1.5)
                entry = try await web.followEntry(anyButton: true)
            }
            guard let name = entry else { return .ready(.generic) }
            // The same button on the same page again: pressing it does nothing the app can see.
            guard pressed.insert("\(before)#\(name)").inserted else { return .ready(.generic) }
            Log.info("Pressed “\(name)” to reach the application")
            step("Pressed “\(name)”")
        }
        return .ready(web.url.map(detect) ?? .generic)
    }

    /// A form drawn in a frame: Greenhouse, Lever, Ashby or Workday in a careers page, a frame from the same site
    /// holding more of the form than the page (iCIMS), or one big frame on a page without a form. Opens the frame's
    /// own page and returns what it is; nil when there's no such frame.
    @MainActor
    static func openFramedForm(_ web: WebAgent, pageFields: Int) async throws -> ATSType? {
        let frames = ((try? await web.js(Scripts.frames)) as? [[String: Any]]) ?? []
        // (Videos, maps, chats and banners; ceros.com is a story told in pictures: SAIC's career page; Pixlee shows
        // photos with a "Next" of its own: Carnival's.)
        let junk = Regex(#"pixlee|olapic|curalate|yotpo|bazaarvoice|stackla|taggbox|juicer\.io|flockler|walls\.io|recaptcha|hcaptcha|captcha|youtube|vimeo|google\.com/maps|doubleclick|demdex|googletag|facebook|twitter|chat|intercom|drift|zendesk|onetrust|cookie|ccpa|gdpr|consent|privacy|truste|usercentrics|ceros\.com|vidyard|wistia|brightcove|jwplayer|kaltura|panopto|issuu|flipsnack|spotify|soundcloud|instagram|tiktok|matterport"#)
        let usable = frames.compactMap { f -> (url: URL, area: Int, shown: Bool, fields: Int, entry: Bool)? in
            guard let src = f["src"] as? String, let url = URL(string: src), !junk.matches(src) else { return nil }
            return (url, (f["area"] as? NSNumber)?.intValue ?? 0, (f["shown"] as? Bool) ?? false, (f["fields"] as? NSNumber)?.intValue ?? -1,
                    (f["entry"] as? Bool) ?? false)
        }
        for f in usable where [.greenhouse, .lever, .ashby, .workday].contains(detect(f.url)) {
            Log.info("Opening the embedded \(detect(f.url).label) form: \(f.url.absoluteString)")
            try await web.load(f.url)
            return detect(f.url)
        }
        if let f = usable.first(where: { $0.fields >= max(2, pageFields + 1) }) {
            Log.info("Opening the form drawn in a frame: \(f.url.absoluteString)")
            try await web.load(f.url)
            return .generic
        }
        if pageFields < 2, let f = usable.first(where: { $0.shown && $0.area > 100_000 && ($0.fields != 0 || $0.entry) }) {
            Log.info("Opening a frame that may hold the form: \(f.url.absoluteString)")
            try await web.load(f.url)
            return .generic
        }
        return nil
    }
}
