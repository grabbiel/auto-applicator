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
let nextPattern = #"^(next|continue|save (and|&) continue|next step|continue to next step|review|review application)\b"#
let applyEntryPattern = #"^(apply( now| for this (job|position|role)| here| online)?|start (my )?application|i'?m interested)$"#

/// Shared logic for filling an application, step by step. Subclasses know a particular site.
@MainActor
public class ApplicationHandler {
    public class var ats: ATSType { .generic }
    /// Areas whose controls must never be touched (search boxes, cookie banners, …).
    class var exclude: [String] {
        ["header", "nav", "footer", "[role=search]", "#onetrust-consent-sdk", "[id*=cookie i]", "[class*=cookie i]"]
    }

    let web: WebAgent
    let ctx: ApplyContext
    private var coverLetter: String?

    public required init(web: WebAgent, ctx: ApplyContext) {
        self.web = web
        self.ctx = ctx
    }

    public func apply() async throws -> ApplyResult {
        try await runFormFlow(root: nil)
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
        guard let data = await web.pdf() else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        let name = "\(f.string(from: Date())) \(tag) – \(ctx.company) – \(ctx.job.title)".replacingOccurrences(of: "/", with: "-")
        let url = ctx.paths.evidenceDir.appendingPathComponent(String(name.prefix(120)) + ".pdf")
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
        ctx.answerer.flagUnresolved(res, jobID: ctx.jobID, company: ctx.company)
        let questions = res.unresolved.map(\.label).joined(separator: "; ")
        ctx.step("Waiting for your answer: \(questions.prefix(140))")
        return ApplyResult(.needsAnswer, notes: "Needs your answer: \(questions.prefix(500))", externalURL: web.url?.absoluteString)
    }

    func practiceResult() async -> ApplyResult {
        ctx.step("Practice mode: stopped before the final Submit")
        return ApplyResult(.practiceComplete, notes: "Practice run: everything was filled in; stopped before the final Submit button.",
                           evidence: await saveEvidence("Practice"), externalURL: web.url?.absoluteString)
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
    func handleDocuments(_ fields: [FormField]) async throws -> (handled: Set<String>, missing: [String]) {
        var handled = Set<String>()
        var missing: [String] = []
        let hasResumeField = fields.contains { $0.kind == .file && $0.fileKind == "resume" }
        for f in fields {
            if f.kind == .file {
                handled.insert(f.id)
                if !f.spec.currentValue.isEmpty { continue }
                let kind = f.fileKind
                if kind == "resume" || (kind == nil && f.spec.required && !hasResumeField) {
                    if await web.upload(f, ctx.paths.resumeFile) { ctx.step("Attached your resume") } else { missing.append(f.spec.label.isEmpty ? "resume" : f.spec.label) }
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
    }

    func fillStep(root: String?, exclude: [String]? = nil) async throws -> FillOutcome {
        let fields = await web.extractFields(root: root, exclude: exclude ?? Self.exclude)
        let (handled, missing) = try await handleDocuments(fields)
        let todo = fields.filter { !handled.contains($0.id) }
        if !todo.isEmpty { ctx.step("Answering \(todo.count) question\(todo.count == 1 ? "" : "s")") }
        let res = await ctx.answerer.resolve(todo.map(\.spec), job: ctx.job)
        try Task.checkCancellation()
        if res.blocked { return FillOutcome(fields: fields, blocked: res, missingFiles: missing) }
        var failures: [String] = []
        for f in todo {
            guard let answer = res.answers[f.id] else { continue }
            if !(await web.fill(f, answer)) { failures.append(f.describe) }
            try await shortPause()
        }
        if !res.answers.isEmpty {
            let learned = res.sources.values.filter { $0 == "cache" || $0 == "memory" }.count
            ctx.step("Filled \(res.answers.count) answer\(res.answers.count == 1 ? "" : "s")" + (learned > 0 ? " (\(learned) from what you taught it)" : ""))
        }
        Log.info("Filled \(res.answers.count) field(s) (\(res.leftBlank.count) left blank, \(failures.count) failed)")
        return FillOutcome(fields: fields, failures: failures, missingFiles: missing)
    }

    /// Answers again the fields the form rejected, giving the AI the error messages.
    func fixErrors(_ errors: [String: String], root: String?, exclude: [String]? = nil) async throws -> FillOutcome {
        let fields = await web.extractFields(root: root, exclude: exclude ?? Self.exclude)
        var targets = fields.filter { errors[$0.id] != nil && $0.kind != .file }
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
            await web.clickFoundButton()
            try await web.sleep(1.8)
            let errors = await web.collectErrors(root: root)
            if errors.isEmpty { return (true, nil) }
            Log.info("Validation errors (attempt \(attempt + 1)): \(Array(errors.values.prefix(4)))")
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
    func runFormFlow(root: String?) async throws -> ApplyResult {
        for _ in 0..<ctx.limits.maxFormSteps {
            try Task.checkCancellation()
            let outcome = try await fillStep(root: root)
            if let blocked = outcome.blocked { return needsAnswer(blocked) }
            if !outcome.missingFiles.isEmpty { return await failure("Couldn't attach: \(outcome.missingFiles.joined(separator: ", "))") }
            if await web.findButton(submitPattern, root: root) == nil {
                guard await web.findButton(nextPattern, root: root) != nil else { return await failure("No Next or Submit button on the form.") }
                let (advanced, result) = try await clickAndValidate(root: root) { await web.findButton(nextPattern, root: root) != nil }
                if !advanced { return result! }
                ctx.step("Next page of the form")
                try await stepPause()
                continue
            }
            if ctx.practice { return await practiceResult() }
            let submittedAt = Date()
            ctx.step("Submitting")
            let (advanced, result) = try await clickAndValidate(root: root) { await web.findButton(submitPattern, root: root) != nil }
            if !advanced { return result! }
            if let early = try await afterSubmit(submittedAt: submittedAt) { return early }
            if await confirmSubmitted() {
                return ApplyResult(.applied, notes: "Sent through \(Self.ats.label)", evidence: await saveEvidence("Sent"), externalURL: web.url?.absoluteString)
            }
            return await failure("Pressed Submit but couldn't confirm the application went through.")
        }
        return await failure("Gave up after \(ctx.limits.maxFormSteps) form pages.")
    }

    /// On a job posting, presses its "Apply" button to reach the form.
    func clickApplyEntry() async throws {
        guard await web.findButton(applyEntryPattern) != nil else { return }
        let before = web.url
        await web.clickFoundButton()
        try await web.sleep(2)
        if web.url != before { try? await web.waitForLoad() }
    }
}

/// Any other careers site: label-driven filling with the Next/Submit loop.
final class GenericHandler: ApplicationHandler {
    override class var ats: ATSType { .generic }

    override func apply() async throws -> ApplyResult {
        if await web.fieldCount() < 3 {
            try await clickApplyEntry()
            try await web.sleep(1.5)
        }
        if await web.hasPasswordField() {
            return await failure("This careers site needs an account to apply. Only Workday accounts are created automatically.")
        }
        if await web.fieldCount() == 0 { return await failure("No application form on the company's site.") }
        return try await runFormFlow(root: nil)
    }
}
