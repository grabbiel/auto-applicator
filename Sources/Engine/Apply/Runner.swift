import Foundation

public enum RunEvent: Sendable {
    /// What the run is doing overall ("Searching “iOS Engineer” — page 1").
    case phase(String)
    case jobStarted(JobCard)
    /// A step within the current job ("Attached your resume").
    case step(String)
    case jobFinished(JobCard, ATSType?, ApplyResult)
    case warning(String)
}

public struct RunSummary: Sendable, Equatable {
    public var practice: Bool
    public var sent = 0
    public var prepared = 0
    public var needsAnswer = 0
    public var failed = 0
    public var looked = 0
    public var note = ""

    public var headline: String {
        let done = practice ? "\(prepared) practice application\(prepared == 1 ? "" : "s") ready" : "\(sent) application\(sent == 1 ? "" : "s") sent"
        var parts = [done]
        if needsAnswer > 0 { parts.append("\(needsAnswer) need\(needsAnswer == 1 ? "s" : "") your answer") }
        if failed > 0 { parts.append("\(failed) didn't finish") }
        return parts.joined(separator: " · ")
    }
}

public enum RunError: LocalizedError, Sendable {
    case notReady(String)
    case signedOut

    public var errorDescription: String? {
        switch self {
        case .notReady(let m): m
        case .signedOut: "You're signed out of LinkedIn. Sign in again from Settings › LinkedIn."
        }
    }
}

/// One run: search LinkedIn, skip what the filters exclude, apply to each job with the right handler, record what
/// happened.
@MainActor
public final class JobRunner {
    let paths: AppPaths
    let web: WebAgent
    let ai: AIService?
    let db: Database
    let practice: Bool
    let onEvent: (RunEvent) -> Void
    private var summary: RunSummary

    public init(paths: AppPaths, db: Database, web: WebAgent, ai: AIService?, practice: Bool, onEvent: @escaping (RunEvent) -> Void) {
        self.paths = paths
        self.db = db
        self.web = web
        self.ai = ai
        self.practice = practice
        self.onEvent = onEvent
        summary = RunSummary(practice: practice)
    }

    public func run() async throws -> RunSummary {
        let store = Store(paths: paths)
        let profile = store.loadProfile() ?? Profile()
        let settings = store.loadSettings()
        let secrets = store.loadSecrets()
        guard profile.isComplete else { throw RunError.notReady("Your profile needs a name, email and phone first.") }
        guard store.resumePresent else { throw RunError.notReady("Add your resume first (Profile › Resume).") }
        let queries = settings.search.cleanKeywords
        guard !queries.isEmpty else { throw RunError.notReady("Add at least one job title to search for (Job search).") }

        onEvent(.phase("Checking your LinkedIn sign-in"))
        guard await web.linkedInSignedIn() else { throw RunError.signedOut }
        if ai == nil { onEvent(.warning("The AI isn't available, so only questions it already knows will be answered.")) }

        let answerer = Answerer(profile: profile, db: db, ai: ai, batchSize: ai?.batchSize ?? 6)
        let verifier = EmailVerifier(secrets: secrets, ai: ai)
        let runID = db.startRun(practice: practice)
        defer {
            db.finishRun(runID, sent: summary.sent, prepared: summary.prepared, needsAnswer: summary.needsAnswer, failed: summary.failed,
                         note: summary.note)
        }
        do {
            queryLoop: for keywords in queries {
                for page in 0..<settings.search.maxPages {
                    if quotaReached(settings) { break queryLoop }
                    try Task.checkCancellation()
                    onEvent(.phase("Searching “\(keywords)” — page \(page + 1)"))
                    let cards = try await web.searchPage(keywords: keywords, search: settings.search, page: page)
                    for card in cards {
                        if quotaReached(settings) { break queryLoop }
                        try await consider(card, settings: settings, profile: profile, secrets: secrets, answerer: answerer, verifier: verifier)
                    }
                    if cards.count < LinkedIn.pageSize { break }
                }
            }
            if quotaReached(settings) { summary.note = "Reached the limit of \(settings.limits.maxAppliesPerRun) per run." }
        } catch is CancellationError {
            summary.note = "Stopped."
        } catch let error as URLError where error.code == .cancelled {
            summary.note = "Stopped."
        }
        onEvent(.phase(summary.headline))
        return summary
    }

    private func quotaReached(_ settings: Settings) -> Bool {
        summary.sent + summary.prepared >= settings.limits.maxAppliesPerRun
    }

    private func consider(_ card: JobCard, settings: Settings, profile: Profile, secrets: Secrets, answerer: Answerer, verifier: EmailVerifier) async throws {
        if let reason = LinkedIn.filterReason(card, settings.filters) {
            db.upsertJob(card.id, status: reason, title: card.title, company: card.company, location: card.location, url: card.url.absoluteString)
            return
        }
        if card.applied {
            db.upsertJob(card.id, status: .skippedAlreadyApplied, title: card.title, company: card.company, url: card.url.absoluteString)
            return
        }
        if db.skipReason(card.id, practice: practice, maxAttempts: settings.limits.maxAttemptsPerJob) != nil { return }

        summary.looked += 1
        onEvent(.jobStarted(card))
        var ats: ATSType?
        var result: ApplyResult
        do {
            let details = try await web.openJob(card)
            switch details.kind {
            case .applied:
                db.upsertJob(card.id, status: .skippedAlreadyApplied, title: card.title, company: card.company, url: card.url.absoluteString)
                onEvent(.jobFinished(card, nil, ApplyResult(.skippedAlreadyApplied, notes: "You applied before.")))
                return
            case .external where !settings.search.includeExternal:
                onEvent(.jobFinished(card, nil, ApplyResult(.skippedTitleFilter, notes: "Applies on the company's site (turned off).")))
                return
            case .closed, .unknown:
                result = ApplyResult(.failedForm, notes: details.kind == .closed ? "No longer accepting applications." : "No apply button on this posting.")
            case .easyApply, .external:
                let job = JobContext(title: card.title, company: card.company, location: card.location, description: details.description)
                let ctx = ApplyContext(jobID: card.id, job: job, settings: settings, paths: paths, profile: profile, db: db, answerer: answerer,
                                       ai: ai, verifier: verifier, secrets: secrets, practice: practice) { [weak self] in self?.onEvent(.step($0)) }
                if details.kind == .easyApply {
                    ats = .easyApply
                    result = try await EasyApplyHandler(web: web, ctx: ctx).apply()
                } else {
                    onEvent(.step("Opening the company's site"))
                    try await web.openExternalApplication()
                    var detected = web.url.map(SiteRouter.detect) ?? .generic
                    if detected == .generic { detected = try await SiteRouter.resolveEmbedded(web) }
                    ats = detected
                    onEvent(.step("Applying through \(detected.label)"))
                    result = try await SiteRouter.handler(detected).init(web: web, ctx: ctx).apply()
                    if result.externalURL == nil { result.externalURL = web.url?.absoluteString }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.error("Job \(card.id) failed: \(error.localizedDescription)")
            result = ApplyResult(.failedForm, notes: "Browser problem: \(error.localizedDescription.prefix(200))")
        }

        db.upsertJob(card.id, status: result.status, title: card.title, company: card.company, location: card.location, ats: ats,
                     url: card.url.absoluteString, externalURL: result.externalURL, notes: result.notes, evidence: result.evidence?.path,
                     countAttempt: result.status.isFailure)
        switch result.status {
        case .applied: summary.sent += 1
        case .practiceComplete: summary.prepared += 1
        case .needsAnswer: summary.needsAnswer += 1
        case .failedForm, .failedOTPTimeout: summary.failed += 1
        default: break
        }
        onEvent(.jobFinished(card, ats, result))
        let lo = settings.limits.minDelaySec, hi = max(lo, settings.limits.maxDelaySec)
        try await web.sleep(Double.random(in: lo...hi))
    }
}
