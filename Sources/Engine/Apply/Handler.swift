import Foundation

public struct ApplyResult: Sendable {
    public var status: JobStatus
    public var notes: String
    public var evidence: URL?
    public var externalURL: String?

    public init(_ status: JobStatus, notes: String = "", evidence: URL? = nil, externalURL: String? = nil) {
        self.status = status
        self.notes = notes
        self.evidence = evidence
        self.externalURL = externalURL
    }
}

/// Everything a handler needs for one job.
@MainActor
public final class ApplyContext {
    public let jobID: String
    public let job: JobContext
    public let settings: Settings
    public let paths: AppPaths
    public let profile: Profile
    public let db: Database
    public let answerer: Answerer
    public let ai: AIService?
    public let verifier: EmailVerifier
    public let secrets: Secrets
    public let practice: Bool
    let step: (String) -> Void

    public init(jobID: String, job: JobContext, settings: Settings, paths: AppPaths, profile: Profile, db: Database, answerer: Answerer,
                ai: AIService?, verifier: EmailVerifier, secrets: Secrets, practice: Bool, step: @escaping (String) -> Void) {
        self.jobID = jobID
        self.job = job
        self.settings = settings
        self.paths = paths
        self.profile = profile
        self.db = db
        self.answerer = answerer
        self.ai = ai
        self.verifier = verifier
        self.secrets = secrets
        self.practice = practice
        self.step = step
    }

    var limits: Limits { settings.limits }
    var company: String { job.company }
}

/// Phrases that mean an application went through.
let successPattern = Regex(
    #"thank(s| you)[^.!\n]{0,40}(for (applying|your (application|interest|submission))|application)|"#
        + #"application (has been |was )?(successfully )?(submitted|received|sent|complete)|"#
        + #"we('ve| have) received your application|your application (has been|was) (submitted|received|sent)"#)
let submitPattern = #"^(submit( (my )?application)?|send application|apply|complete application|finish)$"#
/// Buttons that move a form on without sending the application: Next, a sign-up's "Create account", "Verify" after
/// an emailed code, "I acknowledge" under a privacy notice, "Skip & continue" past an optional step (Amazon's SMS
/// updates). Buttons that sign in with another company's account ("Continue with GitHub") are never pressed.
let nextPattern = #"^(next|continue|save (and|&) continue|skip (and|&) continue|next step|continue to next step|review|review application|proceed|"#
    + #"verify|verify (email|code|and continue)|confirm|submit code|i acknowledge|acknowledge|i agree|agree and continue|accept and continue|"#
    + #"create( an| my)? (account|profile)|register|sign ?up|join|get started|start( my)? application|save and next)\b"#
/// The button that closes a popup over the form once it's answered.
let popupDonePattern = #"^(save|ok|okay|done|accept|i accept|agree|i agree|confirm|continue)$"#
/// The way in for someone without an account on a site that shows a sign-in box.
let newAccountPattern = #"^(create( an| a new| your)? (account|profile)|register( now| here)?|sign ?up( now| here)?|new (user|candidate|applicant)s?\??|"#
    + #"first time (here|applying|user|applicant)\??|i'?m applying for the first time|apply without (an )?account|continue as (a )?guest|apply as (a )?guest|"#
    + #"without (a )?resume|i'?m new( here)?|(don'?t|do not) have an account( yet)?\??( (sign up|register|create (one|an account)))?)$"#
/// A sign-up page saying the email already has an account.
let accountExists = Regex(#"already (exists|registered(?!\s*\?)|in use|taken|been (registered|used)|associated|linked)|already have an account(?!\s*\?)|"#
    + #"account (with (this|that|the) e-?mail( address)? )?already|e-?mail( address)? (is |has )?already|an account (with|for) (this|that|the|your) e-?mail( address)? exists"#)
/// The way to reset a forgotten password.
let forgotPasswordPattern = #"^(forgot(ten)?( your| my| the)? password|reset( your| my)? password|trouble (signing|logging) in|can'?t (sign|log) ?in|"#
    + #"lost( your)? password|need help (signing|logging) in|forgot (your |my )?(login|sign ?in|username or password))"#
/// The way back to the sign-in box from a sign-up page.
let signInLinkPattern = #"^(already have an account\??( (sign|log) ?in)?|(sign|log) ?in( here| instead)?|existing (user|candidate|applicant)s?\??)$"#
/// The button that asks for the reset email, and the one that saves the new password.
let resetSendPattern = #"^(reset( my| your)? password|send( (me )?(a |the )?(reset )?(link|e-?mail|code|instructions))?|submit|continue|next|request( (a )?(reset|link))?|"#
    + #"e-?mail me|get( a)? (reset )?link|recover( password)?)\b"#
let setPasswordPattern = #"^((re)?set|change|update|save|create|confirm|submit|continue|done)( (my|your|the|new))*( password)?\b"#
/// A button found without a known name that would send the application (so practice mode stops there).
let finalButtonWords = Regex(#"\b(submit|send|apply|finish|complete)\b"#)

/// Shared logic for filling an application, step by step. Subclasses know a particular site.
@MainActor
public class ApplicationHandler {
    public class var ats: ATSType { .generic }
    /// Areas whose controls must never be touched (search boxes, cookie banners, …).
    class var exclude: [String] {
        ["header", "nav", "footer", "[role=search]", "#onetrust-consent-sdk", "[id*=cookie i]", "[class*=cookie i]", "[id*=chat i]", "[class*=chat i]"]
    }

    let web: WebAgent
    let ctx: ApplyContext
    private var coverLetter: String?
    /// When the app last pressed a button (an emailed code or link is newer than that).
    var lastActionAt = Date()
    /// The page with the application, to come back to after confirming an email address.
    var applicationURL: URL?
    private var accountSteps = 0
    private var signInTried = false
    private var firstTimeUploadTried = false
    /// The password was reset once on this site (never again in the same application).
    var resetTried = false
    /// A sign-up page turned out to be for an email with an account, whose password was reset instead.
    private var accountRecovered = false
    /// Password boxes on this page were filled for a new account: its button makes the account (in practice mode
    /// too, since that doesn't send the application).
    private var registeringPage = false
    /// A resume went into a file box on this page (sites that read it fill the form a moment later).
    var attachedResume = false

    public required init(web: WebAgent, ctx: ApplyContext) {
        self.web = web
        self.ctx = ctx
    }

    public func apply() async throws -> ApplyResult {
        try await runFormFlow(root: nil)
    }

    /// Stops this job with a note (and a copy of the page).
    public func stop(_ note: String, _ status: JobStatus = .failedForm) async -> ApplyResult {
        await failure(note, status)
    }

    // MARK: pacing and evidence

    func shortPause() async throws {
        if ctx.limits.maxDelaySec > 0 { try await web.sleep(Double.random(in: 0.25...0.6)) }
    }

    func stepPause() async throws {
        let lo = ctx.limits.minDelaySec, hi = max(ctx.limits.minDelaySec, ctx.limits.maxDelaySec)
        try await web.sleep(Double.random(in: lo...hi) / 2)
    }

    /// Saves the whole page as a PDF next to the application record.
    func saveEvidence(_ tag: String) async -> URL? {
        await Self.savePage(web, paths: ctx.paths, tag: tag, company: ctx.company, title: ctx.job.title)
    }

    /// Saves the page as a PDF in the evidence folder ("2026-11-15 1552 Stopped – Company – Title.pdf").
    static func savePage(_ web: WebAgent, paths: AppPaths, tag: String, company: String, title: String) async -> URL? {
        guard let data = await web.pdf() else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        let name = "\(f.string(from: Date())) \(tag) – \(company) – \(title)".replacingOccurrences(of: "/", with: "-")
        let url = paths.evidenceDir.appendingPathComponent(String(name.prefix(120)) + ".pdf")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            Log.warn("Couldn't save the page: \(error.localizedDescription)")
            return nil
        }
    }

    func failure(_ note: String, _ status: JobStatus = .failedForm) async -> ApplyResult {
        Log.warn("\(ctx.company): \(note)")
        return ApplyResult(status, notes: note, evidence: await saveEvidence("Stopped"), externalURL: web.url?.absoluteString)
    }

    func needsAnswer(_ res: Resolution) -> ApplyResult {
        if let f = res.declined.first {
            ctx.step("Skipped: it requires “\(f.contextLabel.prefix(80))”, which you can't answer")
            return ApplyResult(.skippedCantAnswer, notes: Database.cantAnswerNote(f.contextLabel), externalURL: web.url?.absoluteString)
        }
        ctx.answerer.flagUnresolved(res, jobID: ctx.jobID, company: ctx.company)
        let questions = res.unresolved.map(\.contextLabel).joined(separator: "; ")
        ctx.step("Waiting for your answer: \(questions.prefix(140))")
        return ApplyResult(.needsAnswer, notes: "Needs your answer: \(questions.prefix(500))", externalURL: web.url?.absoluteString)
    }

    func practiceResult() async -> ApplyResult {
        ctx.step("Practice mode: stopped before the final Submit")
        let robot = await web.hasRobotBox() ? " A real run would stop here too: the site asks you to tick “I'm not a robot”." : ""
        return ApplyResult(.practiceComplete, notes: "Practice run: everything was filled in; stopped before the final Submit button." + robot,
                           evidence: await saveEvidence("Practice"), externalURL: web.url?.absoluteString)
    }

    /// The note for a form that wants a person to tick "I'm not a robot" before it's sent.
    var robotBoxNote: String {
        "\(siteName) asks you to tick “I'm not a robot” before sending, which the app never does. Apply on their site yourself."
    }

    /// The site's name for messages: its host without "www." (e.g. "intuit.avature.net").
    var siteName: String {
        guard let host = web.url?.host?.lowercased() else { return ctx.company }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Words that pick out this site's emails: the company's name and the site's own name ("schwab|icims").
    var emailHint: String {
        let skip: Set<String> = ["www", "careers", "career", "jobs", "job", "apply", "recruiting", "boards", "com", "net", "org", "io", "co",
                                 "app", "passport", "login", "auth", "account", "accounts", "secure", "global", "talent", "hire", "external",
                                 "inc", "corp", "company", "group", "llc", "the", "technologies", "services", "solutions", "international"]
        var parts: [String] = []
        if let host = web.url?.host?.lowercased() {
            parts += host.split(separator: ".").map(String.init).filter { $0.count >= 4 && !skip.contains($0) && !$0.hasPrefix("wd") }
        }
        parts += ctx.company.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 4 && !skip.contains($0) }
        var seen = Set<String>()
        return parts.filter { seen.insert($0).inserted }.joined(separator: "|")
    }

    // MARK: documents

    func coverLetterText() async throws -> String {
        if let coverLetter { return coverLetter }
        guard let ai = ctx.ai else { throw AIError.unavailable("No AI to write a cover letter.") }
        ctx.step("Writing a cover letter")
        let text = try await ai.coverLetter(profile: ctx.profile, job: ctx.job)
        coverLetter = text
        return text
    }

    func coverLetterFile() async throws -> URL {
        if let own = ctx.profile.files.coverLetterPDF {
            let url = own.hasPrefix("/") ? URL(fileURLWithPath: own) : ctx.paths.home.appendingPathComponent(own)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let text = try await coverLetterText()
        let safe = ctx.company.replacingOccurrences(of: #"[^A-Za-z0-9]+"#, with: "-", options: .regularExpression).prefix(40)
        let url = ctx.paths.coverLettersDir.appendingPathComponent("Cover Letter - \(ctx.profile.personal.fullName) - \(safe).pdf")
        try PDFWriter.letter(text, title: "Cover letter – \(ctx.job.title)").write(to: url, options: .atomic)
        return url
    }

    /// Uploads the resume and cover letter and writes cover-letter text boxes. Returns the ids it handled and the
    /// required uploads it couldn't do.
    static let fillFromResume = Regex(#"\b(fill|complete|populate)s?( out| in)? (your |my |the |this )?(application|form|profile) (with|from|using) (your |my |the )?(resume|cv)\b|"#
        + #"\bautomatically (fill|complete|populate)|\bauto-?fill\b|\b(parse|import) (your |my )?(resume|cv)\b"#)

    func handleDocuments(_ fields: [FormField]) async throws -> (handled: Set<String>, missing: [String]) {
        var handled = Set<String>()
        var missing: [String] = []
        let hasResumeField = fields.contains { $0.kind == .file && $0.fileKind == "resume" }
        // A box that has the site fill the form from the resume (Paylocity's "Fill out application with my resume"):
        // unticked before the resume goes in, so what the site misreads ("Peru" for Country, the last name as the
        // middle name) never replaces the profile's answers.
        for f in fields where f.kind == .checkbox && Self.fillFromResume.matches(norm(f.spec.label)) {
            handled.insert(f.id)
            if f.spec.currentValue == "Yes", await web.fill(f, "No") { Log.info("Unticked “\(f.spec.label)”") }
        }
        // The same offer as a popup's own upload button ("Upload your resume and we'll automatically fill out your
        // application"): the form's resume box is used instead.
        let resumeBoxes = fields.filter { $0.kind == .file && $0.fileKind == "resume" }
        let offers = resumeBoxes.filter { Self.fillFromResume.matches(norm($0.spec.label)) }
        // (When every resume box says so, the last is the form's own: the popup's comes first.)
        let autofillBoxes = resumeBoxes.count < 2 ? [] : Set((offers.count == resumeBoxes.count ? Array(offers.dropLast()) : offers).map(\.id))
        for f in fields {
            if autofillBoxes.contains(f.id) {
                handled.insert(f.id)
                continue
            }
            if f.kind == .file {
                handled.insert(f.id)
                if !f.spec.currentValue.isEmpty { continue }
                let kind = f.fileKind
                if kind == "resume" || (kind == nil && f.spec.required && !hasResumeField) {
                    if await web.upload(f, ctx.paths.resumeFile) { ctx.step("Attached your resume"); attachedResume = true } else { missing.append(f.spec.label.isEmpty ? "resume" : f.spec.label) }
                } else if kind == "cover_letter" && (f.spec.required || ctx.profile.files.coverLetterPDF != nil) {
                    do {
                        if await web.upload(f, try await coverLetterFile()) { ctx.step("Attached a cover letter") } else { missing.append(f.spec.label) }
                    } catch is CancellationError { throw CancellationError() } catch {
                        missing.append("\(f.spec.label) (\(error.localizedDescription))")
                    }
                } else if f.spec.required {
                    missing.append(f.spec.label.isEmpty ? "file upload" : f.spec.label)
                }
                try await shortPause()
            } else if f.kind == .text, Regex(#"cover[\s_-]*letter"#).matches(f.spec.label), f.spec.currentValue.isEmpty {
                handled.insert(f.id)
                if f.spec.required || f.spec.type == .textarea {
                    do {
                        _ = await web.fill(f, try await coverLetterText())
                    } catch is CancellationError { throw CancellationError() } catch {
                        if f.spec.required { missing.append("\(f.spec.label) (\(error.localizedDescription))") }
                    }
                }
            }
        }
        return (handled, missing)
    }

    // MARK: form steps

    struct FillOutcome {
        var fields: [FormField] = []
        var blocked: Resolution?
        var failures: [String] = []
        var missingFiles: [String] = []
        /// The job can't go on (e.g. an emailed code never came).
        var stop: ApplyResult?
    }

    func fillStep(root: String?, exclude: [String]? = nil) async throws -> FillOutcome {
        let fields = await web.extractFields(root: root, exclude: exclude ?? Self.exclude)
        // A code the site emailed is read from the inbox; it's never a question for the person.
        let digitBoxes = fields.filter { $0.kind == .text && $0.spec.maxLength == 1 }
        let codeBoxes = (4...8).contains(digitBoxes.count) ? digitBoxes : fields.filter(\.isEmailCode)
        let codeIDs = Set(codeBoxes.map(\.id))
        if codeBoxes.contains(where: { $0.spec.currentValue.isEmpty }), let stop = try await enterEmailCode(codeBoxes) {
            return FillOutcome(fields: fields, stop: stop)
        }
        var rest = fields.filter { !codeIDs.contains($0.id) }
        attachedResume = false
        let (handled, missing) = try await handleDocuments(rest)
        var shown = fields
        // A site that reads the resume fills the form from it a moment later (Paylocity put "Peru" in Country and
        // swapped the address boxes for others): what it filled is read once it's done, not the page from before.
        if attachedResume, await web.waitForFormToSettle(root: root) {
            ctx.step("Reading what \(siteName) filled in from your resume")
            shown = await web.extractFields(root: root, exclude: exclude ?? Self.exclude)
            rest = shown.filter { $0.kind != .file && !codeIDs.contains($0.id) && !handled.contains($0.id) }
        }
        // Country before the rest: setting it redraws the address boxes (Paylocity's Locality, Administrative Area and
        // Postal Code for Peru become City, County, State and ZIP Code for the United States).
        if let country = rest.first(where: { Regex(#"^country( of residence)?$"#).matches(norm($0.spec.label)) && !$0.spec.currentValue.isEmpty }),
           let answer = (await ctx.answerer.resolve([country.spec], job: ctx.job)).answers[country.id],
           !Answerer.sameAnswer(answer, country.spec.currentValue), await web.fill(country, answer) {
            Log.info("Set Country to \(answer) before the rest of the form (it was \(country.spec.currentValue))")
            await web.waitForFormToSettle(root: root, quiet: 1, timeout: 6)
            shown = await web.extractFields(root: root, exclude: exclude ?? Self.exclude)
            rest = shown.filter { $0.kind != .file && !codeIDs.contains($0.id) && !handled.contains($0.id) }
        }
        let todo = rest.filter { !handled.contains($0.id) }
        if !todo.isEmpty { ctx.step("Answering \(todo.count) question\(todo.count == 1 ? "" : "s")") }
        var res = await ctx.answerer.resolve(todo.map(\.spec), job: ctx.job)
        try Task.checkCancellation()
        if res.blocked { return FillOutcome(fields: shown, blocked: res, missingFiles: missing) }
        var failures: [String] = []
        for f in todo {
            guard let answer = res.answers[f.id] else { continue }
            if !(await web.fill(f, answer)) { failures.append(f.describe) }
            try await shortPause()
        }
        // An answer that redraws part of the form (Country = United States brings back City, State and ZIP in place
        // of Locality and Postal Code) leaves the boxes found before it gone: the page is read again and what's
        // still empty, or still not the person's own details, is answered once more.
        if !failures.isEmpty {
            await web.waitForFormToSettle(root: root, quiet: 1, timeout: 6)
            let again = await web.extractFields(root: root, exclude: exclude ?? Self.exclude)
                .filter { $0.kind != .file && !codeIDs.contains($0.id) }
            let res2 = await ctx.answerer.resolve(again.map(\.spec), job: ctx.job)
            try Task.checkCancellation()
            if res2.blocked { return FillOutcome(fields: again, blocked: res2, missingFiles: missing) }
            if !res2.answers.isEmpty {
                Log.info("Answering again after the form redrew: \(res2.answers.count) field(s)")
                failures = []
                for f in again {
                    guard let answer = res2.answers[f.id] else { continue }
                    if !(await web.fill(f, answer)) { failures.append(f.describe) }
                    try await shortPause()
                }
                for (k, v) in res2.answers { res.answers[k] = v }
                for (k, v) in res2.sources { res.sources[k] = v }
                shown = again
            }
        }
        if !res.answers.isEmpty {
            let learned = res.sources.values.filter { $0 == "cache" || $0 == "memory" }.count
            ctx.step("Filled \(res.answers.count) answer\(res.answers.count == 1 ? "" : "s")" + (learned > 0 ? " (\(learned) from what you taught it)" : ""))
        }
        Log.info("Filled \(res.answers.count) field(s) (\(res.leftBlank.count) left blank, \(failures.count) failed)" +
                 (failures.isEmpty ? "" : ": " + failures.prefix(6).map { String($0.prefix(60)) }.joined(separator: "; ")))
        return FillOutcome(fields: shown, failures: failures, missingFiles: missing)
    }

    /// Reads the code the site just emailed and types it in (one box, or one box per character).
    func enterEmailCode(_ boxes: [FormField]) async throws -> ApplyResult? {
        guard ctx.verifier.configured else {
            return await failure("\(siteName) emailed a code, but email isn't connected (Settings › Email codes).", .failedOTPTimeout)
        }
        let split = boxes.count >= 4 && boxes.allSatisfy { $0.spec.maxLength == 1 }
        let length = split ? boxes.count : boxes.first?.spec.maxLength.flatMap { (4...10).contains($0) ? $0 : nil }
        ctx.step("Checking your email for the code \(siteName) sent")
        let since = min(lastActionAt, Date()).addingTimeInterval(-90)
        guard let res = await ctx.verifier.waitForVerification(senderHint: emailHint, since: since, timeout: TimeInterval(max(ctx.limits.otpTimeoutSec, 120)),
                                                               kind: .code, codeLength: length),
              let code = res.code else {
            return await failure("\(siteName) emailed a code, but it didn't arrive within \(max(ctx.limits.otpTimeoutSec, 120)) seconds.", .failedOTPTimeout)
        }
        if split {
            // Typed as a person would, so boxes that move on by themselves keep each digit (Oracle's at Uber kept
            // only the first when each box was set on its own); box by box when that didn't take.
            await web.click(boxes[0].selector)
            var typed = await web.typeKeys(code)
            if typed {
                try? await web.sleep(0.4)
                let got = ((try? await web.js("return sels.map(s => { const e = document.querySelector(s); return e ? e.value : ''; }).join('')",
                                               ["sels": boxes.map(\.selector)])) as? String) ?? ""
                typed = got == String(code.prefix(boxes.count))
            }
            if !typed {
                for (box, ch) in zip(boxes, code) { await web.fill(box.selector, String(ch)) }
            }
        } else if let box = boxes.first {
            await web.fill(box.selector, code)
        }
        ctx.step("Entered the code from your email")
        return nil
    }

    /// "Check your email": opens the confirmation link the site sent, then goes back to the application.
    func confirmEmailLink() async throws -> ApplyResult? {
        guard ctx.verifier.configured else {
            return await failure("\(siteName) wants you to confirm your email, but email isn't connected (Settings › Email codes).", .failedOTPTimeout)
        }
        ctx.step("Waiting for \(siteName)'s email to confirm your address")
        let wait = max(ctx.limits.otpTimeoutSec, 180)
        guard let res = await ctx.verifier.waitForVerification(senderHint: emailHint, since: min(lastActionAt, Date()).addingTimeInterval(-90),
                                                               timeout: TimeInterval(wait), kind: .link),
              let link = res.url.flatMap(URL.init(string:)) else {
            return await failure("\(siteName)'s email to confirm your address didn't arrive within \(wait) seconds.", .failedOTPTimeout)
        }
        try await web.load(link)
        try await web.sleep(3)
        await web.dismissBanners()
        let page = await web.pageKind()
        if page.fields < 2 && page.passwords == 0, let back = applicationURL {
            try await web.load(back)
            try await web.sleep(2)
        }
        lastActionAt = Date()
        return nil
    }

    /// Before each page of a form: closes cookie banners and waits out an automatic "are you human?" check.
    func prepareStep() async throws -> ApplyResult? {
        if let idp = SiteRouter.identityProvider(web.url) { return await failure(SiteRouter.identityStop(idp)) }
        await web.dismissBanners()
        await web.closeResumeImport()
        let page = await web.pageKind()
        switch page.kind {
        case .botcheck:
            ctx.step("Waiting for \(siteName)'s security check")
            if !(await web.waitOutBotCheck()) { return await failure(await web.botCheckNote(siteName)) }
            try? await web.waitForLoad(timeout: 15)
            await web.dismissBanners()
        case .emaillink:
            return try await confirmEmailLink()
        default:
            break
        }
        return nil
    }

    /// A sign-in or sign-up box. A new account is made with the profile's email and the portal password (the rest of
    /// a sign-up page is filled like any form); on a site where the app made one before, it signs in; a sign-in box
    /// with a way in for first-time visitors takes that way. Returns a result to stop with, or nil to go on.
    /// `moved` is true when the gate went to another page (fill nothing on this one).
    func accountGate() async throws -> (stop: ApplyResult?, moved: Bool) {
        guard let form = await web.accountForm() else { return (nil, false) }
        // Never on Apple's, Google's or Microsoft's own sign-in pages (prepareStep stops there too).
        if let idp = SiteRouter.identityProvider(web.url) { return (await failure(SiteRouter.identityStop(idp)), false) }
        accountSteps += 1
        if accountSteps > 5 { return (await failure("Couldn't get past \(siteName)'s sign-in."), false) }
        let password = ctx.secrets.portalPassword
        guard !password.isEmpty else {
            return (await failure("\(siteName) needs an account, but no portal password is set (Settings › Accounts)."), false)
        }
        let host = web.url?.host ?? ""
        let email = ctx.profile.personal.email
        if form.kind == .register {
            // The portal password opens an account here already: sign in rather than sign up again.
            if ctx.db.hasAccount(host: host), !signInTried, let name = await web.findButton(signInLinkPattern) {
                ctx.step("Pressing “\(name)”: you have an account on \(siteName)")
                await web.clickFoundButton()
                lastActionAt = Date()
                try await web.sleep(2)
                try? await web.waitForLoad(timeout: 10)
                return (nil, true)
            }
            ctx.step("Creating an account on \(siteName) with your email")
            await web.fillPasswords(password)
            registeringPage = true
            return (nil, false)
        }
        // A sign-in box.
        if ctx.db.hasAccount(host: host) && !signInTried {
            return (try await signIn(email: email, password: password, form: form), false)
        }
        // The account the app made (or reset) here no longer opens with the portal password.
        if ctx.db.hasAccount(host: host) && !resetTried {
            return (try await resetPassword(), true)
        }
        // Once: a resume box that does nothing by itself (MANTECH's hidden one, behind a "From Device" dialog) leaves
        // the sign-in box where it was, and the way in for new applicants ("Without Resume") is taken instead.
        if form.firstTimeUpload && !firstTimeUploadTried {
            firstTimeUploadTried = true
            ctx.step("Starting as a first-time applicant with your resume")
            let before = web.url
            if await web.setFiles(#"[data-auto-firsttime-upload="1"]"#, [ctx.paths.resumeFile]) {
                lastActionAt = Date()
                var moved = false
                for _ in 0..<20 {
                    try await web.sleep(0.5)
                    if web.url != before { moved = true; break }
                    if await web.accountForm() == nil { moved = true; break }
                }
                if moved {
                    try? await web.waitForLoad(timeout: 15)
                    return (nil, true)
                }
                Log.info("\(siteName): the resume box for first-time applicants did nothing")
            }
        }
        if let name = await web.findButton(newAccountPattern) {
            ctx.step("Pressing “\(name)” to apply as a new applicant")
            let before = web.url
            await web.clickFoundButton()
            lastActionAt = Date()
            try await web.sleep(2)
            if web.url != before { try? await web.waitForLoad() }
            return (nil, true)
        }
        if !signInTried {
            return (try await signIn(email: email, password: password, form: form), false)
        }
        // Signing in didn't work and there's no way in for new applicants: an account for the email with another
        // password (made by hand, or before the portal password).
        if !resetTried { return (try await resetPassword(), true) }
        return (await failure("\(siteName) asks you to sign in, and signing in with your email and portal password didn't work."), false)
    }

    /// The site has an account for the person's email that the portal password doesn't open: resets it to the
    /// portal password through the site's "Forgot password" email, so one password opens every site. Returns a
    /// result to stop with, or nil once the password is set (back on the application, to sign in again).
    func resetPassword() async throws -> ApplyResult? {
        resetTried = true
        registeringPage = false
        let password = ctx.secrets.portalPassword, email = ctx.profile.personal.email
        let site = siteName, signInHost = web.url?.host
        guard ctx.verifier.configured else {
            return await failure("\(site) already has an account for your email, with another password. The app resets it to your portal password "
                                 + "through the site's reset email, but email isn't connected (Settings › Email codes).", .failedOTPTimeout)
        }
        if await web.findButton(forgotPasswordPattern) == nil, let name = await web.findButton(signInLinkPattern) {
            ctx.step("Pressing “\(name)” to reach \(site)'s sign-in")
            await web.clickFoundButton()
            try await web.sleep(2)
            try? await web.waitForLoad(timeout: 10)
        }
        guard let forgot = await web.findButton(forgotPasswordPattern) else {
            return await failure("\(site) already has an account for your email, with another password, and the app found no way to reset it. "
                                 + "Reset it on their site to your portal password (Settings › Company-site accounts).")
        }
        ctx.step("\(site) already has an account for your email: resetting its password to your portal password")
        ctx.step("Pressing “\(forgot)”")
        await web.clickFoundButton()
        try await web.sleep(2)
        try? await web.waitForLoad(timeout: 10)
        guard await web.fillEmailBox(email) else {
            return await failure("\(site)'s password reset page had no box for your email.")
        }
        let since = Date()
        if await web.hasButton(resetSendPattern) {
            await web.clickFoundButton()
        } else {
            await web.press(.enter)
        }
        lastActionAt = Date()
        try await web.sleep(3)
        ctx.step("Waiting for \(site)'s password reset email")
        let wait = max(ctx.limits.otpTimeoutSec, 180)
        guard let res = await ctx.verifier.waitForVerification(senderHint: emailHint, since: since.addingTimeInterval(-30), timeout: TimeInterval(wait),
                                                               kind: .reset) else {
            return await failure("\(site)'s password reset email didn't arrive within \(wait / 60) minutes.", .failedOTPTimeout)
        }
        if let link = res.url.flatMap(URL.init(string:)) {
            ctx.step("Opening the reset link from \(site)'s email")
            try await web.load(link)
            try await web.sleep(2.5)
            await web.dismissBanners()
        } else if let code = res.code {
            let boxes = (await web.extractFields(exclude: Self.exclude)).filter(\.isEmailCode)
            guard let box = boxes.first else { return await failure("\(site) emailed a reset code, but its page had no box for it.") }
            await web.fill(box.selector, code)
            ctx.step("Entered the reset code from your email")
        }
        _ = await web.fillEmailBox(email, onlyEmpty: true)
        guard await web.fillPasswords(password) > 0 else {
            return await failure("\(site)'s password reset page had no box for the new password.")
        }
        ctx.step("Setting your portal password as the new password")
        if await web.hasButton(setPasswordPattern) {
            await web.clickFoundButton()
        } else {
            await web.press(.enter)
        }
        lastActionAt = Date()
        try await web.sleep(4)
        try? await web.waitForLoad(timeout: 15)
        let errors = await web.collectErrors()
        if !errors.isEmpty, await web.hasPasswordField() {
            return await failure("\(site) didn't take your portal password as the new password: \(errors.values.prefix(2).joined(separator: "; "))")
        }
        for host in Set([signInHost, applicationURL?.host].compactMap { $0 }) { ctx.db.noteAccount(host: host, email: email, how: .reset) }
        ctx.step("Reset the password on \(site) to your portal password")
        if let back = applicationURL {
            try await web.load(back)
            try await web.sleep(2)
        }
        signInTried = false
        return nil
    }

    private func signIn(email: String, password: String, form: WebAgent.AccountForm) async throws -> ApplyResult? {
        signInTried = true
        ctx.step("Signing in to \(siteName)")
        if form.hasUser { await web.fill(#"[data-auto-user="1"]"#, email) }
        await web.fill(#"[data-auto-account] input[type=password]"#, password)
        if await web.exists(#"[data-auto-account-btn="1"]"#) { await web.click(#"[data-auto-account-btn="1"]"#) } else { await web.press(.enter) }
        lastActionAt = Date()
        try await web.sleep(4)
        try? await web.waitForLoad(timeout: 15)
        if let still = await web.accountForm(), still.kind == .login {
            Log.info("\(siteName): signing in didn't work")
            return nil  // the gate tries another way in on the next step
        }
        if let host = web.url?.host { ctx.db.noteAccount(host: host, email: email, how: .signedIn) }
        return nil
    }

    /// Answers again the fields the form rejected, giving the AI the error messages.
    func fixErrors(_ errors: [String: String], root: String?, exclude: [String]? = nil) async throws -> FillOutcome {
        await web.closeResumeImport()
        let fields = await web.extractFields(root: root, exclude: exclude ?? Self.exclude)
        var targets = fields.filter { errors[$0.id] != nil && $0.kind != .file && !$0.isEmailCode }
        for i in targets.indices {
            targets[i].spec.error = errors[targets[i].id] ?? ""
            targets[i].spec.required = true
        }
        ctx.step("Fixing \(targets.count) answer\(targets.count == 1 ? "" : "s") the form didn't accept")
        let res = await ctx.answerer.resolve(targets.map(\.spec), job: ctx.job, feedback: errors.filter { k, _ in targets.contains { $0.id == k } })
        if res.blocked { return FillOutcome(fields: fields, blocked: res) }
        var failures: [String] = []
        for f in targets {
            if let answer = res.answers[f.id], !(await web.fill(f, answer)) { failures.append(f.describe) }
        }
        return FillOutcome(fields: fields, failures: failures)
    }

    /// Presses Next/Submit (found by `find`, which tags the button); on validation errors answers again and retries.
    func clickAndValidate(root: String?, exclude: [String]? = nil, retries: Int = 2, find: () async -> Bool) async throws -> (Bool, ApplyResult?) {
        for attempt in 0...retries {
            guard await find() else { return (false, await failure("The Next/Submit button disappeared.")) }
            if registeringPage { await web.fillPasswords(ctx.secrets.portalPassword) }  // some sites clear them on an error
            await web.clickFoundButton()
            lastActionAt = Date()
            try await web.sleep(1.8)
            let errors = await web.collectErrors(root: root)
            if errors.isEmpty { return (true, nil) }
            Log.info("Validation errors (attempt \(attempt + 1)): \(Array(errors.values.prefix(4)))")
            // Signing up with an email that already has an account here: reset that account's password instead.
            if registeringPage, !resetTried, accountExists.matches(errors.values.joined(separator: " ")) {
                if let stop = try await resetPassword() { return (false, stop) }
                accountRecovered = true
                return (true, nil)
            }
            if attempt == retries { break }
            let fix = try await fixErrors(errors, root: root, exclude: exclude)
            if let blocked = fix.blocked { return (false, needsAnswer(blocked)) }
        }
        let msgs = (await web.collectErrors(root: root)).values.prefix(4).joined(separator: "; ")
        return (false, await failure("The form didn't accept the answers: \(msgs)"))
    }

    func confirmSubmitted(timeout: TimeInterval = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if successPattern.matches(await web.text()) { return true }
            try? await web.sleep(1)
        }
        guard let ai = ctx.ai, let check = try? await ai.checkSubmission(pageText: await web.text()) else { return false }
        return check.submitted
    }

    /// For steps after Submit, such as an emailed security code. Return a result to finish early.
    func afterSubmit(submittedAt: Date) async throws -> ApplyResult? { nil }

    /// Fill what's visible, press Next until a Submit button appears, then submit (or stop there in practice mode).
    /// Sign-in and sign-up pages, emailed codes and links, cookie banners and bot checks are handled on the way.
    func runFormFlow(root: String?) async throws -> ApplyResult {
        if applicationURL == nil { applicationURL = web.url }
        var lastPage: String?
        var samePage = 0
        for _ in 0..<(ctx.limits.maxFormSteps + 4) {
            try Task.checkCancellation()
            if let stop = try await prepareStep() { return stop }
            let gate = try await accountGate()
            if let stop = gate.stop { return stop }
            if gate.moved { continue }
            // A popup over the form that wants something first (Dayforce's privacy statement, to agree to and Save):
            // this step is the popup. Its "Submit" is still taken for the application's.
            let popup = await web.blockingDialog()
            let root = popup == nil ? root : WebAgent.blockingDialogRoot
            if let popup {
                Log.info("\(siteName) shows a popup over the form first: \(popup)")
                ctx.step("Answering “\(popup)” first")
            }
            let outcome = try await fillStep(root: root)
            if let stop = outcome.stop { return stop }
            if let blocked = outcome.blocked { return needsAnswer(blocked) }
            if !outcome.missingFiles.isEmpty { return await failure("Couldn't attach: \(outcome.missingFiles.joined(separator: ", "))") }

            let page = (web.url?.absoluteString ?? "") + "|" + (popup ?? "") + "|" + outcome.fields.map(\.spec.label).joined(separator: "|")
            samePage = page == lastPage ? samePage + 1 : 0
            lastPage = page
            if samePage >= 3 { return await failure("The form didn't move on (same page four times).") }

            var hasSubmit = false
            if !registeringPage { hasSubmit = await web.findButton(submitPattern, root: root) != nil }
            if !hasSubmit {
                // On a sign-up page its "Submit" makes the account; it doesn't send the application.
                var find: () async -> Bool = {
                    if await self.web.findButton(nextPattern, root: root) != nil { return true }
                    // A popup's own "Save" or "OK" (on a form, "Save" keeps a draft).
                    if popup != nil, await self.web.findButton(popupDonePattern, root: root) != nil { return true }
                    if self.registeringPage { return await self.web.findButton(submitPattern, root: root) != nil }
                    return false
                }
                if !(await find()) {
                    // A button with a name the patterns don't know ("Send code", "Save & Proceed").
                    guard let other = await web.findPrimaryButton(root: root) else { return await failure("No Next or Submit button on the form.") }
                    if finalButtonWords.matches(other) && !registeringPage {
                        if ctx.practice { return await practiceResult() }
                        return try await submit(root: root) { await self.web.findPrimaryButton(root: root) != nil }
                    }
                    find = { await self.web.findPrimaryButton(root: root) != nil }
                }
                let (advanced, result) = try await clickAndValidate(root: root, find: find)
                if !advanced { return result! }
                if accountRecovered {
                    accountRecovered = false
                    continue
                }
                if registeringPage {
                    registeringPage = false
                    // Some sites say so above the form instead of next to the email box.
                    if !resetTried, await web.accountForm() != nil, accountExists.matches(await web.text(maxChars: 4000)) {
                        if let stop = try await resetPassword() { return stop }
                        continue
                    }
                    if let host = web.url?.host { ctx.db.noteAccount(host: host, email: ctx.profile.personal.email) }
                    ctx.step("Made an account on \(siteName)")
                } else if popup == nil {
                    ctx.step("Next page of the form")
                }
                try await stepPause()
                continue
            }
            if ctx.practice { return await practiceResult() }
            return try await submit(root: root) { await self.web.findButton(submitPattern, root: root) != nil }
        }
        return await failure("Gave up after \(ctx.limits.maxFormSteps) form pages.")
    }

    private func submit(root: String?, find: () async -> Bool) async throws -> ApplyResult {
        if await web.hasRobotBox() { return await failure(robotBoxNote) }
        let submittedAt = Date()
        ctx.step("Submitting")
        let (advanced, result) = try await clickAndValidate(root: root, find: find)
        if !advanced { return result! }
        if let early = try await afterSubmit(submittedAt: submittedAt) { return early }
        if await confirmSubmitted() {
            return ApplyResult(.applied, notes: "Sent through \(Self.ats.label)", evidence: await saveEvidence("Sent"), externalURL: web.url?.absoluteString)
        }
        return await failure("Pressed Submit but couldn't confirm the application went through.")
    }

    /// On a job posting, presses its "Apply" button (or opens its link in this tab) to reach the form.
    func clickApplyEntry() async throws {
        if let name = try await web.followEntry() { ctx.step("Pressed “\(name)”") }
    }
}

/// Any other careers site: label-driven filling with the Next/Submit loop.
final class GenericHandler: ApplicationHandler {
    override class var ats: ATSType { .generic }

    override func apply() async throws -> ApplyResult {
        if let idp = SiteRouter.identityProvider(web.url) { return await failure(SiteRouter.identityStop(idp)) }
        let page = await web.pageKind()
        if page.fields < 2 && page.passwords == 0 && page.kind == .page {
            // An email box with Next (iCIMS's first step) is a step of the form: Next waits for the email.
            var emailStep = false
            if page.fields == 1 { emailStep = (try? await web.js(Scripts.tagEmailBox)) is String }
            if let name = try await web.followEntry(anyButton: !emailStep) { ctx.step("Pressed “\(name)”") }
            if let idp = SiteRouter.identityProvider(web.url) { return await failure(SiteRouter.identityStop(idp)) }
        }
        let now = await web.pageKind()
        // A step of the application without questions (Amazon's "Get SMS updates", with "Skip & continue") is still
        // the application, and so is a page with only a resume drop zone.
        if now.fields == 0 && now.passwords == 0 && !now.upload && now.kind == .page, await web.findButton(nextPattern, root: nil) == nil {
            // Only a way in through another account (Fonzi's "Connect LinkedIn"): the app never connects one.
            if let other = await web.findButton(#"^(connect|link|sign in with|log ?in with|continue with)\s+(your\s+)?(linkedin|google|github|apple|microsoft|facebook|indeed)( account| profile)?$"#) {
                return await failure("\(siteName) only lets you in with “\(other)”. The app never connects your accounts to a site; apply there yourself.")
            }
            return await failure("No application form on the company's site.")
        }
        return try await runFormFlow(root: nil)
    }
}
