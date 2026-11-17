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
    /// The cloud AI, asked what to do when a form gets stuck (runs in the cloud browser only).
    public let helper: AIService?
    let step: (String) -> Void

    public init(jobID: String, job: JobContext, settings: Settings, paths: AppPaths, profile: Profile, db: Database, answerer: Answerer,
                ai: AIService?, verifier: EmailVerifier, secrets: Secrets, practice: Bool, helper: AIService? = nil,
                step: @escaping (String) -> Void) {
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
        self.helper = helper
        self.step = step
    }

    var limits: Limits { settings.limits }
    var company: String { job.company }
}

/// Phrases that mean an application went through.
let successPattern = Regex(
    #"thank(s| you)[^.!\n]{0,40}(for (applying|your (application|interest|submission))|application)|"#
        + #"application (has been |was )?(successfully )?(submitted|received|sent|complete)|"#
        + #"we('ve| have) received your application|your application (has been|was) (submitted|received|sent)|"#
        // German, French, Spanish, Dutch and Italian.
        + #"(vielen )?dank für (deine|ihre) bewerbung|(deine|ihre) bewerbung (wurde|ist) (erfolgreich )?(versendet|eingegangen|übermittelt)|"#
        + #"merci (pour|de) votre candidature|votre candidature a (bien )?été (envoyée|reçue|transmise)|"#
        + #"gracias por (tu|su) (solicitud|postulaci[oó]n|candidatura)|bedankt voor je sollicitatie|grazie per (la tua|la sua) candidatura"#)
// Kula's "Apply for this position" ends its form; before any question it opens one instead (`entryApplyPattern`).
let submitPattern = #"^(submit( (my )?application)?|send application|apply|apply now|apply for (this|the) (job|position|role)|complete application|finish|solliciteer( nu)?|"#
    // German, French, Spanish, Dutch and Italian (Personio's "Bewerbung senden").
    + #"bewerbung (senden|abschicken|absenden|einreichen)|absenden|abschicken|envoyer( ma| la| votre)? candidature|soumettre( ma| la)?( candidature)?|"#
    + #"enviar( mi| la)?( solicitud| candidatura| postulaci[oó]n)?|sollicitatie (versturen|verzenden)|versturen|verzenden|invia( la)?( candidatura)?)$"#
/// Buttons that move a form on without sending the application: Next, a sign-up's "Create account", "Verify" after
/// an emailed code, "I acknowledge" under a privacy notice, "Skip & continue" past an optional step (Amazon's SMS
/// updates). Buttons that sign in with another company's account ("Continue with GitHub") are never pressed.
let nextPattern = #"^(next|continue|save (and|&) continue|skip (and|&) continue|next step|continue to next step|review|review application|proceed|"#
    + #"verify|verify (email|code|and continue)|confirm|submit code|i acknowledge|acknowledge|i agree|agree (and|&) continue|accept (and|&) continue|consent (and|&) continue|"#
    + #"create( an| my)? (account|profile)|register|sign ?up|join(?! (our|the|us)\b)|get started|start( my)? application|save and next|"#
    + #"weiter|nächster schritt|suivant|continuer|étape suivante|siguiente|continuar|volgende|verder|avanti|continua|próximo|seguinte)\b"#
/// The button that has a site send a verification code, once it's been told where (ADP's "Send").
let sendCodePattern = #"^(send|send( me)?( a| the| my)?( verification| security| one[- ]time| login)? code|get( a| the)?( verification)? code|"#
    + #"e-?mail( me)?( a| the)?( verification)? code|request( a| the)?( verification)? code)$"#
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
let finalButtonWords = Regex(#"\b(submit|send|apply|finish|complete|senden|absenden|abschicken|envoyer|soumettre|enviar|versturen|verzenden|invia)\b"#)
/// A button that opens an application rather than sending one, when nothing has been asked yet.
let entryApplyPattern = #"^apply( now| online| for (this|the) (job|position|role))?$"#
let entryApplyWords = Regex(entryApplyPattern)

/// Shared logic for filling an application, step by step. Subclasses know a particular site.
@MainActor
public class ApplicationHandler {
    public class var ats: ATSType { .generic }
    /// Areas whose controls must never be touched (search boxes, cookie banners, …). A consent banner sits
    /// outside the form; consent statements inside it (Adobe's, id "usConsentObject") are the application's.
    class var exclude: [String] {
        ["header", "nav", "footer", "[role=search]", "#onetrust-consent-sdk", "#usercentrics-root", "#usercentrics-cmp-ui", "[id*=consent i]:not(body):not(html):not(form):not(form *)", "[id*=cookie i]:not(body):not(html)", "[class*=cookie i]:not(body):not(html)", "[id*=chat i]:not(body):not(html)", "[class*=chat i]:not(body):not(html)"]
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
    /// The sign-up page's "Sign in" pressed once for an account the app knows of; back on the sign-up, there's none.
    private var signInLinkTried = false
    private var firstTimeUploadTried = false
    /// The password was reset once on this site (never again in the same application).
    var resetTried = false
    /// A sign-up page turned out to be for an email with an account, whose password was reset instead.
    private var accountRecovered = false
    /// The page was given its few seconds to draw the form.
    private var waitedForForm = false
    /// Password boxes on this page were filled for a new account: its button makes the account (in practice mode
    /// too, since that doesn't send the application).
    private var registeringPage = false
    /// What the sign-up page said when it came back without making the account.
    private var signUpError: String?
    /// A resume went into a file box on this page (sites that read it fill the form a moment later).
    var attachedResume = false
    /// Times the cloud AI may still be asked what to do on a stuck form (see Rescue.swift).
    var rescuesLeft = 4
    /// Buttons remembered from this site's earlier applications, already tried in this one.
    var triedLearned = Set<String>()

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

    func practiceResult(notTaken: [String] = []) async -> ApplyResult {
        ctx.step("Practice mode: stopped before the final Submit")
        let robot = await web.hasRobotBox() ? " A real run would stop here too: the site asks you to tick “I'm not a robot” (or pass its security check)." : ""
        // Answers the last page didn't take (a date picker that emptied itself): said, not "everything was filled in".
        let filled = notTaken.isEmpty ? "everything was filled in"
            : "filled in except \(notTaken.prefix(4).joined(separator: ", ")), which the form didn't take (a real run tries again after Submit)"
        return ApplyResult(.practiceComplete, notes: "Practice run: \(filled); stopped before the final Submit button." + robot,
                           evidence: await saveEvidence("Practice"), externalURL: web.url?.absoluteString)
    }

    /// The note for a form that wants a person to tick "I'm not a robot" before it's sent.
    var robotBoxNote: String {
        "\(siteName) asks you to tick “I'm not a robot” (or pass its security check) before sending, which the app never does. Apply on their site yourself."
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
        + #"\bautomatically (fill|complete|populate)|\bauto-?fill\b|\b(parse|import) (your |my )?(resume|cv)\b|"#
        + #"\bauto-?complete (your |my |the )?(application|form|profile)\b|\bapply with (your |my |a )?(resume|cv)\b"#)

    /// A box for the cover letter, or for the note to the people hiring that takes its place (SmartRecruiters' "Let the
    /// company know about your interest working there").
    static let coverLetterBox = Regex(#"cover[\s_-]*letter|^(a |your )?message to (the )?hiring (team|manager)|^let the (company|employer|hiring team|team) know (about )?(your|why)"#)

    /// Whether a page without a resume box is searched for one it keeps hidden (not in LinkedIn's Easy Apply, which
    /// keeps the resumes uploaded before and has its own hidden upload box).
    var lookForHiddenResumeBox: Bool { true }

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
                    // Already attached: a box that shows the file beside it and empties itself (Rippling's "resume.pdf"),
                    // where attaching again has the site read the resume again and redo the boxes it fills from it.
                    if await web.bool("return (document.body.innerText || '').includes(name);", ["name": ctx.paths.resumeFile.lastPathComponent]) {
                        try await shortPause()
                        continue
                    }
                    if await web.upload(f, ctx.paths.resumeFile) { ctx.step("Attached your resume"); attachedResume = true } else { missing.append(f.spec.label.isEmpty ? "resume" : f.spec.label) }
                } else if kind == "cover_letter" && (f.spec.required || ctx.profile.files.coverLetterPDF != nil) {
                    do {
                        if await web.upload(f, try await coverLetterFile()) { ctx.step("Attached a cover letter") } else { missing.append(f.spec.label) }
                    } catch is CancellationError { throw CancellationError() } catch {
                        missing.append("\(f.spec.label) (\(error.localizedDescription))")
                    }
                } else if f.spec.required {
                    // A file the person never gave the app (Workable's required "Photo"): said so, without the box's
                    // own "Choose file" button.
                    let label = f.spec.label.replacingOccurrences(of: #"\s*\b(choose|select|browse|upload|attach|add|replace)( a| your)? files?\b.*$"#,
                                                                  with: "", options: [.regularExpression, .caseInsensitive]).trimmed
                    missing.append("\(label.isEmpty ? "a file" : "“\(label)”"), which you haven't given the app")
                }
                try await shortPause()
            } else if f.kind == .text, Self.coverLetterBox.matches(norm(f.spec.label)), f.spec.currentValue.isEmpty {
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
        // No resume box shown, but one the page keeps hidden behind a button (Jobvite's "Add Resume*: Select").
        if lookForHiddenResumeBox, !hasResumeField, !attachedResume, await web.attachToHiddenResumeBox(ctx.paths.resumeFile) {
            ctx.step("Attached your resume")
            attachedResume = true
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
        /// Optional questions left blank because neither AI could answer them.
        var unanswered: [FieldSpec] = []
    }

    /// The person's own phone number box (not a reference's or an emergency contact's).
    static func ownPhone(_ f: FormField) -> Bool {
        guard f.kind == .text, !["Work experience", "Education", "References", "Emergency contact", "Referral"].contains(f.spec.section) else { return false }
        return f.spec.type == .tel || Regex(#"^(mobile |cell |primary |home )?phone( number)?$"#).matches(norm(f.spec.label))
    }

    func fillStep(root: String?, exclude: [String]? = nil) async throws -> FillOutcome {
        let fields = await web.extractFields(root: root, exclude: exclude ?? Self.exclude)
        if ProcessInfo.processInfo.environment["AA_TRACE_FILL"] != nil {
            Log.info("TRACE page \(web.url?.absoluteString.prefix(90) ?? "") root=\(root ?? "-"): \(fields.map { "\($0.kind) \($0.spec.label.prefix(30))=\($0.spec.currentValue.prefix(20))" })")
        }
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
        if let country = rest.first(where: { Regex(#"^(current )?country( of (current )?residence)?$"#).matches(norm($0.spec.label)) && !$0.spec.currentValue.isEmpty }),
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
        let trace = ProcessInfo.processInfo.environment["AA_TRACE_FILL"] != nil
        for f in todo {
            // A phone box with its own country list (Workable's, set to where the computer is): the number's own
            // country first, then the number again, which the wrong country may have spoiled.
            if Self.ownPhone(f), res.sources[f.id] ?? "profile" == "profile",
               let set = await web.matchPhoneCountry(f, code: ctx.profile.personal.phoneCountryCode,
                                                     names: WorkdayHandler.countryNames(ctx.profile.personal.address.country)) {
                ctx.step("Set the phone's country code to \(set)")
                if res.answers[f.id] == nil, !ctx.profile.personal.phone.trimmed.isEmpty { res.answers[f.id] = ctx.profile.personal.phone }
            }
            guard var answer = res.answers[f.id] else { continue }
            // A box that holds the number with its country's code ("+20", Recruitee's, from where the computer is): the
            // number with its own code, which sets the box's country too. (Typed without it, "512…" became Peru's +51.)
            if Self.ownPhone(f), !answer.trimmed.hasPrefix("+"), f.spec.currentValue.trimmed.hasPrefix("+") {
                let code = ctx.profile.personal.phoneCountryCode.filter(\.isNumber)
                if !code.isEmpty { answer = "+\(code) \(WorkdayHandler.nationalNumber(answer, code: code))" }
            }
            let ok = await web.fill(f, answer)
            // A decline an optional list has no way to give (Pinpoint's Gender: Male, Female, Non-Binary): left blank,
            // as it may be.
            if !ok, !(isDecline(answer) && !f.spec.required) { failures.append(f.describe) }
            if trace {
                let why = ok ? "" : " " + (await web.string(Scripts.prelude + "const e = document.querySelector(sel); if (!e) return 'gone'; const r = e.getBoundingClientRect(); const h = document.elementFromPoint(r.left + Math.min(r.width / 2, 20), r.top + r.height / 2); return 'shown=' + shown(e) + ' value=' + String(e.value || '').slice(0, 20) + ' hit=' + (h ? h.tagName + '.' + String(h.className || '').slice(0, 40) : '-');", ["sel": f.selector]))
                Log.info("TRACE \(f.kind) “\(f.spec.label.prefix(50))” was “\(f.spec.currentValue.prefix(30))” ← “\(answer.prefix(40))” [\(res.sources[f.id] ?? "?")] ok=\(ok)\(why)")
            }
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
        // A list with nothing to choose until an answer above it is in (Conduent's State / Province, filled in once the
        // Country is chosen): read again, and answered now that it has choices.
        let waiting = Set(todo.filter { f in
            f.kind == .select && res.answers[f.id] == nil && res.leftBlank.contains { $0.id == f.id }
                && !f.spec.options.contains { !isPlaceholderOption($0) && !$0.trimmed.isEmpty }
        }.map(\.id))
        if failures.isEmpty, !waiting.isEmpty, !res.answers.isEmpty {
            await web.waitForFormToSettle(root: root, quiet: 1, timeout: 4)
            let ready = await web.extractFields(root: root, exclude: exclude ?? Self.exclude)
                .filter { waiting.contains($0.id) && $0.spec.options.contains { !isPlaceholderOption($0) && !$0.trimmed.isEmpty } }
            if !ready.isEmpty {
                let res3 = await ctx.answerer.resolve(ready.map(\.spec), job: ctx.job)
                try Task.checkCancellation()
                if res3.blocked { return FillOutcome(fields: shown, blocked: res3, missingFiles: missing) }
                Log.info("Answering \(ready.count) list(s) whose choices came after an answer above them")
                for f in ready {
                    guard let answer = res3.answers[f.id] else { continue }
                    if !(await web.fill(f, answer)) { failures.append(f.describe) }
                    try await shortPause()
                }
                for (k, v) in res3.answers { res.answers[k] = v }
                for (k, v) in res3.sources { res.sources[k] = v }
                res.leftBlank.removeAll { f in res3.answers[f.id] != nil }
            }
        }
        if !res.answers.isEmpty {
            let learned = res.sources.values.filter { $0 == "cache" || $0 == "memory" }.count
            let cloud = res.sources.values.filter { $0.hasPrefix("cloud") }.count
            let notes = (learned > 0 ? ["\(learned) from what you taught it"] : []) + (cloud > 0 ? ["\(cloud) from the cloud AI"] : [])
            ctx.step("Filled \(res.answers.count) answer\(res.answers.count == 1 ? "" : "s")" + (notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))"))
        }
        Log.info("Filled \(res.answers.count) field(s) (\(res.leftBlank.count) left blank, \(failures.count) failed)" +
                 (failures.isEmpty ? "" : ": " + failures.prefix(6).map { String($0.prefix(60)) }.joined(separator: "; ")) +
                 (res.leftBlank.isEmpty ? "" : "; left blank: " + res.leftBlank.prefix(4).map { "“\($0.label.prefix(40))”" }.joined(separator: ", ")))
        return FillOutcome(fields: shown, failures: failures, missingFiles: missing, unanswered: res.unanswered.filter { res.answers[$0.id] == nil })
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
        if accountSteps > 5 {
            return (await failure("Couldn't get past \(siteName)'s sign-in\(signUpError.map { ": its sign-up page said “\($0)”" } ?? ".")"), false)
        }
        let password = ctx.secrets.portalPassword
        guard !password.isEmpty else {
            return (await failure("\(siteName) needs an account, but no portal password is set (Settings › Accounts)."), false)
        }
        let host = web.url?.host ?? ""
        let email = ctx.profile.personal.email
        if form.kind == .register {
            // The portal password opens an account here already: sign in rather than sign up again.
            // Once: back on the sign-up after it (Dice's "Creating for … Not you?"), the site has no account for the
            // email, whatever the app noted, and one is made.
            if ctx.db.hasAccount(host: host), !signInTried, !signInLinkTried, let name = await web.findButton(signInLinkPattern) {
                signInLinkTried = true
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
            // Avature's "From Device" (MetLife's) shows the resume box with its own Continue: pressed by script, so
            // no file picker opens, and its Continue once the resume is in.
            if let opener = (try? await web.js(Scripts.tagFirstTimeOpener)) as? String {
                ctx.step("Pressing “\(opener)”")
                _ = try? await web.js(#"const b = document.querySelector('[data-auto-firsttime-open="1"]'); if (b) b.click(); return !!b;"#)
                try await web.sleep(1)
            }
            if await web.setFiles(#"[data-auto-firsttime-upload="1"]"#, [ctx.paths.resumeFile]) {
                lastActionAt = Date()
                if let go = (try? await web.js(Scripts.tagFirstTimeContinue)) as? String {
                    try await web.sleep(0.5)
                    ctx.step("Pressing “\(go)”")
                    await web.click(#"[data-auto-firsttime-go="1"]"#)
                }
                var moved = false
                for _ in 0..<20 {
                    try await web.sleep(0.5)
                    if web.url != before { moved = true; break }
                    // Gone, or a sign-up in its place: past the sign-in box.
                    if let still = await web.accountForm(), still.kind == .login { continue }
                    moved = true
                    break
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
            // Which boxes they're on, so the log says what the form turned away.
            let labels = Dictionary((await web.extractFields(root: root, exclude: exclude ?? Self.exclude)).map { ($0.id, $0.spec.label) }) { a, _ in a }
            Log.info("Validation errors (attempt \(attempt + 1)): \(errors.prefix(4).map { "\(labels[$0.key].map { String($0.prefix(50)) } ?? "?"): \($0.value)" })")
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
        var msgs = (await web.collectErrors(root: root)).values.prefix(4).joined(separator: "; ")
        // The cloud AI looks at the fields the errors are about (a list the app didn't set, a box in the wrong format).
        if !msgs.isEmpty, case .moved? = try await rescue("After pressing the button, the form shows these errors: \(msgs)", root: root), await find() {
            await web.clickFoundButton()
            lastActionAt = Date()
            try await web.sleep(1.8)
            let errors = await web.collectErrors(root: root)
            if errors.isEmpty { return (true, nil) }
            msgs = errors.values.prefix(4).joined(separator: "; ")
        }
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
        // Boxes seen on the way: before the application has asked anything, a button that only says "Apply" (ADP's
        // job page) opens it, and a job alert's Submit beside the job (Blue Yonder's) isn't the application's.
        var fieldsSeen = 0
        var regrown = 0
        var codeRequests = 0
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
            // Asked where to send a verification code (ADP's, after Continue): the email is chosen, and the question's
            // own "Send" pressed rather than the form's Continue behind it. Twice at most: no flood of codes.
            if codeRequests < 2, let ask = outcome.fields.first(where: { $0.kind == .radio && Regex(ProfileRules.codeDestinationLabel).matches(norm($0.spec.label)) }) {
                guard let mail = ask.spec.options.firstIndex(where: { $0.contains("@") || Regex(#"\be-?mail\b"#).matches(norm($0)) }) else {
                    return await failure("\(siteName) sends its verification code only by text message, which the app can't read.")
                }
                if await web.isChecked(ask.optionSelector(mail)), let name = await web.findButton(sendCodePattern, root: root) {
                    codeRequests += 1
                    Log.info("Pressing “\(name)” to have \(siteName) email a verification code")
                    ctx.step("Asked \(siteName) to email a verification code")
                    lastActionAt = Date()
                    await web.clickFoundButton()
                    try await web.sleep(2)
                    try? await web.waitForLoad(timeout: 10)
                    continue
                }
            }

            fieldsSeen += outcome.fields.count
            let firstPage = fieldsSeen == 0
            // A form that's drawn a few seconds after the page (Phenom's apply page shows the job and a job-alert
            // sign-up first): wait for its questions once before deciding what the page is.
            if firstPage && popup == nil, await questionsAppear(root: root) { continue }
            let opensApplication: (String) -> Bool = { firstPage && entryApplyWords.matches(norm($0)) }
            let page = (web.url?.absoluteString ?? "") + "|" + (popup ?? "") + "|" + outcome.fields.map(\.spec.label).joined(separator: "|")
            samePage = page == lastPage ? samePage + 1 : 0
            lastPage = page
            if samePage >= 3 {
                // Held up by "I am human" (MeeBoss's hCaptcha pops up over its jobs): the person's to do, never the app's.
                if await web.hasRobotBox() {
                    return await failure("\(siteName) shows an “I'm not a robot” check before going on, which the app never does. Apply on their site yourself.")
                }
                switch try await rescue("Pressing the form's Next button four times left the same page.", root: root) {
                case .moved?:
                    samePage = 1
                    continue
                case .submit?:
                    if ctx.practice { return await practiceResult() }
                    return try await submit(root: root) { await self.web.exists(#"[data-auto-btn="1"]"#) }
                case .stop(let why)?:
                    return await failure("The form didn't move on (the cloud AI: \(why))")
                case nil:
                    return await failure("The form didn't move on (same page four times).")
                }
            }

            var hasSubmit = false
            if !registeringPage, let name = await web.findButton(submitPattern, root: root, skipSignUps: firstPage) { hasSubmit = !opensApplication(name) }
            if !hasSubmit {
                // On a sign-up page its "Submit" makes the account; it doesn't send the application.
                var find: () async -> Bool = {
                    if await self.web.findButton(nextPattern, root: root) != nil { return true }
                    // A popup's own "Save" or "OK" (on a form, "Save" keeps a draft).
                    if popup != nil, await self.web.findButton(popupDonePattern, root: root) != nil { return true }
                    if self.registeringPage { return await self.web.findButton(submitPattern, root: root) != nil }
                    if firstPage { return await self.web.findButton(entryApplyPattern, root: root) != nil }
                    return false
                }
                if !(await find()) {
                    // A button with a name the patterns don't know ("Send code", "Save & Proceed").
                    guard let other = await web.findPrimaryButton(root: root) else {
                        // An answer that brought the rest of the form (Jobvite's "Location of Residence" choice shows
                        // the application under it): read the page again.
                        if regrown < 3, await moreQuestions(than: outcome.fields, root: root) {
                            regrown += 1
                            continue
                        }
                        // A Submit or Next that's greyed out: the form wants something it hasn't got.
                        let disabled = await disabledButton(root: root)
                        // Kept off until someone ticks "I'm not a robot" (careerspage.io): as far as the app goes.
                        if let d = disabled, finalButtonWords.matches(norm(d)), await web.hasRobotBox() {
                            if ctx.practice { return await practiceResult() }
                            return await failure(robotBoxNote)
                        }
                        // Kept off until a question the form doesn't mark as required is answered (AbsenceSoft's "Do you
                        // have any connections at AbsenceSoft?" on Rippling), and neither AI could answer one: the person's.
                        if let d = disabled, !outcome.unanswered.isEmpty {
                            Log.info("The form's “\(d)” button is disabled with \(outcome.unanswered.count) question(s) left blank that only you can answer")
                            var ask = Resolution()
                            ask.unresolved = outcome.unanswered
                            return needsAnswer(ask)
                        }
                        let problem = disabled.map { "The form's “\($0)” button is disabled: something it requires is missing or not accepted." }
                            ?? "The app found no Next, Continue or Submit button it knows on this page of the form."
                        switch try await rescue(problem, root: root) {
                        case .moved?:
                            continue
                        case .submit?:
                            if ctx.practice { return await practiceResult() }
                            return try await submit(root: root) { await self.web.exists(#"[data-auto-btn="1"]"#) }
                        case .stop(let why)?:
                            return await failure("No Next or Submit button on the form (the cloud AI: \(why))")
                        case nil:
                            return await failure(disabled.map { "The form's “\($0)” button stayed disabled: something it requires is missing or wasn't accepted." }
                                                 ?? "No Next or Submit button on the form.")
                        }
                    }
                    if finalButtonWords.matches(other) && !registeringPage && !opensApplication(other) {
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
                    // A sign-up that reloads the whole page (Taleo's) shows its errors only once that's done.
                    try? await web.waitForLoad(timeout: 10)
                    // Some sites say so above the form instead of next to the email box.
                    if !resetTried, await web.accountForm() != nil, accountExists.matches(await web.text(maxChars: 4000)) {
                        if let stop = try await resetPassword() { return stop }
                        continue
                    }
                    // The sign-up page back with an error (Taleo's "The value entered in the field “User Name” is
                    // invalid"): no account yet, and none recorded; the answers it turned away are fixed.
                    if let still = await web.accountForm(), still.kind == .register {
                        _ = await web.extractFields(root: root, exclude: Self.exclude)  // a reloaded page's boxes, named again
                        var errors = await web.collectErrors(root: root)
                        // Up to five seconds for its words, while the sign-up is still there.
                        for _ in 0..<10 where errors.isEmpty {
                            try await web.sleep(0.5)
                            guard let again = await web.accountForm(), again.kind == .register else { break }
                            errors = await web.collectErrors(root: root)
                        }
                        if let first = errors.values.first {
                            signUpError = String(first.prefix(200))
                            Log.info("\(siteName): the sign-up page came back: \(errors.values.prefix(2).joined(separator: "; "))")
                            let fix = try await fixErrors(errors, root: root)
                            if let blocked = fix.blocked { return needsAnswer(blocked) }
                            continue
                        }
                    }
                    if let host = web.url?.host { ctx.db.noteAccount(host: host, email: ctx.profile.personal.email) }
                    ctx.step("Made an account on \(siteName)")
                } else if popup == nil {
                    ctx.step("Next page of the form")
                }
                try await stepPause()
                continue
            }
            // Questions drawn after the page was read (Pinpoint draws its phone, address and consent boxes a moment
            // after the name boxes): answered before the final Submit.
            if regrown < 3, await moreQuestions(than: outcome.fields, root: root) {
                regrown += 1
                continue
            }
            if ctx.practice { return await practiceResult(notTaken: outcome.failures) }
            return try await submit(root: root) { await self.web.findButton(submitPattern, root: root) != nil }
        }
        return await failure("Gave up after \(ctx.limits.maxFormSteps) form pages.")
    }

    /// Whether the page shows questions it didn't before (an answer brought them), after a moment to draw them.
    private func moreQuestions(than before: [FormField], root: String?) async -> Bool {
        try? await web.sleep(1.5)
        let seen = Set(before.map { $0.spec.label })
        return await web.extractFields(root: root, exclude: Self.exclude).contains { !seen.contains($0.spec.label) }
    }

    /// Waits up to `timeout` seconds for the page to show questions of an application (once per application).
    func questionsAppear(root: String?, timeout: TimeInterval = 8) async -> Bool {
        guard !waitedForForm else { return false }
        waitedForForm = true
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            try? await web.sleep(1)
            if !(await web.extractFields(root: root, exclude: Self.exclude)).isEmpty { return true }
        }
        return false
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

    /// A visible Submit or Next button that's disabled, by name.
    func disabledButton(root: String?) async -> String? {
        var args: [String: Any] = ["patterns": [submitPattern, nextPattern], "rootSel": NSNull()]
        if let root { args["rootSel"] = root }
        let name = await web.string(Scripts.prelude + #"""
            const scope = (rootSel && document.querySelector(rootSel)) || document;
            const SEL = 'button, input[type=submit], input[type=button], [role=button]';
            for (const p of patterns) {
                const re = new RegExp(p, 'i');
                for (const b of (scope === document ? document.querySelectorAll(SEL) : deepAll(scope, SEL))) {
                    if (!shown(b)) continue;
                    const off = b.disabled || b.getAttribute('aria-disabled') === 'true' || /\bdisabled\b/i.test(b.className || '');
                    const name = words(b) || clean(b.getAttribute('aria-label') || '');
                    if (off && re.test(name)) return name;
                }
            }
            return '';
            """#, args)
        return name.isEmpty ? nil : name
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
        var page = await web.pageKind()
        // An apply page that draws its form a few seconds late (Serco's Phenom page): the form, not the site's
        // "Sign up" link, once it's there.
        if page.fields == 0 && page.passwords == 0 && page.kind == .page, web.url?.absoluteString.lowercased().contains("apply") == true,
           await questionsAppear(root: nil) {
            page = await web.pageKind()
        }
        if page.fields < 2 && page.passwords == 0 && page.kind == .page {
            // An email box with Next (iCIMS's first step) is a step of the form: Next waits for the email.
            var emailStep = false
            if page.fields == 1 { emailStep = (try? await web.js(Scripts.tagEmailBox)) is String }
            if let name = try await web.followEntry(anyButton: !emailStep) { ctx.step("Pressed “\(name)”") }
            if let idp = SiteRouter.identityProvider(web.url) { return await failure(SiteRouter.identityStop(idp)) }
        }
        var now = await web.pageKind()
        // A form drawn a few seconds after its page (Comeet's, in a frame): its questions are waited for once.
        if now.fields == 0 && now.passwords == 0 && !now.upload && now.kind == .page, await questionsAppear(root: nil) {
            now = await web.pageKind()
        }
        // A step of the application without questions (Amazon's "Get SMS updates", with "Skip & continue") is still
        // the application, and so is a page with only a resume drop zone.
        if now.fields == 0 && now.passwords == 0 && !now.upload && now.kind == .page, await web.findButton(nextPattern, root: nil) == nil {
            // Only a way in through another account (Fonzi's "Connect LinkedIn"): the app never connects one.
            if let other = await web.findButton(#"^(connect|link|sign in with|log ?in with|continue with)\s+(your\s+)?(linkedin|google|github|apple|microsoft|facebook|indeed)( account| profile)?$"#) {
                return await failure("\(siteName) only lets you in with “\(other)”. The app never connects your accounts to a site; apply there yourself.")
            }
            // Applications by email only (Acclaim's "Apply via email"): the app never sends mail for the person.
            if let address = await web.applyByEmailAddress() {
                return await failure("\(siteName) takes applications by email, to \(address), which the app doesn't send for you. Email them yourself.")
            }
            switch try await rescue("The app can't find the application form, or a button that leads to it, on this page.", root: nil) {
            case .moved?:
                return try await runFormFlow(root: nil)
            case .stop(let why)?:
                return await failure("No application form on the company's site (the cloud AI: \(why))")
            case .submit?, nil:
                return await failure("No application form on the company's site.")
            }
        }
        return try await runFormFlow(root: nil)
    }
}
