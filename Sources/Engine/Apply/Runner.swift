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
    /// The cloud AI, for questions the on-device AI couldn't answer (runs in the cloud browser only).
    let helper: AIService?
    let db: Database
    let practice: Bool
    let onEvent: (RunEvent) -> Void
    private var summary: RunSummary
    /// When this run began: a question waiting for the person holds back other jobs only once this run has seen a
    /// form ask it (see `consider`).
    private var startedAt = Date()
    /// The company applications this run has opened (see `applicationKey`), with what came of each: another LinkedIn
    /// posting of the same job (Mintive's twice, Haystack's three times) isn't gone through again.
    private var opened: [String: (title: String, result: ApplyResult)] = [:]

    public init(paths: AppPaths, db: Database, web: WebAgent, ai: AIService?, helper: AIService? = nil, practice: Bool,
                onEvent: @escaping (RunEvent) -> Void) {
        self.paths = paths
        self.db = db
        self.web = web
        self.ai = ai
        self.helper = helper
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
        if ai == nil {
            onEvent(.warning(helper == nil ? "The AI isn't available, so only questions it already knows will be answered."
                : "The on-device AI isn't available, so new questions go to the cloud AI (\(helper!.displayName))."))
        }
        // Without LinkedIn's number for the place, signed-in searches show jobs near the profile's location instead.
        let place = settings.search.location.trimmed
        let geoId = place.isEmpty ? nil : await web.linkedInGeoId(for: place)
        if !place.isEmpty && geoId == nil {
            onEvent(.warning("LinkedIn didn't recognize “\(place)”, so it may show jobs near your LinkedIn profile's location. Try a city, state or country in Job search › Where."))
        }

        // Answers worked out from an older profile (an address since corrected) are worked out again.
        let fingerprint = profile.fingerprint
        if db.meta("profile") != fingerprint {
            let forgotten = db.forgetDerivedAnswers()
            if forgotten > 0 { Log.info("The profile changed: forgot \(forgotten) answer(s) worked out from the old one") }
            db.setMeta("profile", fingerprint)
        }
        let answerer = Answerer(profile: profile, db: db, ai: ai, helper: helper, batchSize: ai?.batchSize ?? 6)
        let verifier = EmailVerifier(secrets: secrets, ai: ai)
        let runID = db.startRun(practice: practice)
        startedAt = Date()
        defer {
            db.finishRun(runID, sent: summary.sent, prepared: summary.prepared, needsAnswer: summary.needsAnswer, failed: summary.failed,
                         note: summary.note)
        }
        do {
            // Jobs that waited for answers the person has now given: finish them first, whether or not the search
            // shows them again.
            let answered = db.answeredJobs()
            if !answered.isEmpty { onEvent(.phase("Finishing \(answered.count) application\(answered.count == 1 ? "" : "s") you answered questions for")) }
            for job in answered {
                if quotaReached(settings) { break }
                try Task.checkCancellation()
                let card = JobCard(id: job.id, title: job.title, company: job.company, location: job.location, applied: false)
                try await consider(card, settings: settings, profile: profile, secrets: secrets, answerer: answerer, verifier: verifier)
            }
            queryLoop: for keywords in queries {
                for page in 0..<settings.search.maxPages {
                    if quotaReached(settings) { break queryLoop }
                    try Task.checkCancellation()
                    onEvent(.phase("Searching “\(keywords)” — page \(page + 1)"))
                    let cards = try await web.searchPage(keywords: keywords, search: settings.search, geoId: geoId, page: page)
                    let fitting = cards.filter { LinkedIn.fits($0, settings.search) }
                    if fitting.count < cards.count {
                        Log.info("Left out \(cards.count - fitting.count) of \(cards.count) jobs on page \(page + 1) for “\(keywords)”: not your workplace or level")
                    }
                    for card in fitting {
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

    /// What another posting of the same application came to: sent (in this run or before) means never again; anything
    /// else this run is said again rather than gone through again. Not counted in the run's totals.
    private func sameApplication(_ key: String) -> ApplyResult? {
        if let (title, first) = opened[key] {
            if first.status == .applied { return ApplyResult(.skippedAlreadyApplied, notes: "Sent already through the “\(title.prefix(80))” posting.") }
            return ApplyResult(first.status, notes: "The same application as the “\(title.prefix(80))” posting: \(first.notes)", evidence: first.evidence,
                               externalURL: first.externalURL)
        }
        if db.appliedApplicationKeys().contains(key) { return ApplyResult(.skippedAlreadyApplied, notes: "You applied to this job through another posting.") }
        return nil
    }

    /// One application however a posting links to it: the address without what only tracks the visit ("utm_source",
    /// Haystack's "funnel_source"), keeping what names the job (machinele's "id=38813"). Nil for an address that names no
    /// particular job (a careers home page different postings may share).
    nonisolated static func applicationKey(_ url: URL?) -> String? {
        guard let url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = c.host?.lowercased() else { return nil }
        let tracking = Regex(#"^(utm_.*|src|source|sourcetype|ref|refid|referrer|gh_src|gh_jid_src|funnel_source|share_id|codes|iis|iisn|_?ccid|trackingid|igbtracker|lang|hl|locale|domain|mode|from|_jsource|cmpid|ss|bid|vjk|amp;.*)$"#)
        let kept = (c.queryItems ?? []).filter { !tracking.fullMatch($0.name.lowercased()) }
            .map { "\($0.name.lowercased())=\($0.value ?? "")" }.sorted()
        let key = host.replacingOccurrences(of: "www.", with: "") + c.path.lowercased() + (kept.isEmpty ? "" : "?" + kept.joined(separator: "&"))
        // A job number or an ID in it.
        guard Regex(#"\d{4,}|[0-9a-f]{8}-[0-9a-f]{4}|[a-z]\d{5,}"#).matches(key) else { return nil }
        return key
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
        // Another application to this company waits for the person's answer, and this one would most likely ask it
        // too: it waits with it instead of going through the company's site again (TCS asked four times for a PAN).
        // Only once a form has asked it in this run: one from an earlier run may come from an older version of the app
        // that read the form wrong (machinele's boxes all read "Message" until their labels were fixed), so the site
        // is looked at again first.
        if let waiting = db.pendingQuestion(company: card.company, seenSince: startedAt) {
            db.addPending(waiting.hash, question: waiting.question, fieldType: waiting.fieldType, options: waiting.options, jobID: card.id,
                          company: card.company)
            let result = ApplyResult(.needsAnswer, notes: "Waits for your answer to “\(waiting.question.prefix(200))”, which another \(card.company) application asked.")
            db.upsertJob(card.id, status: .needsAnswer, title: card.title, company: card.company, location: card.location,
                         url: card.url.absoluteString, notes: result.notes)
            summary.needsAnswer += 1
            onEvent(.jobFinished(card, nil, result))
            return
        }
        var ats: ATSType?
        var result: ApplyResult
        var landing: String?
        var duplicate = false
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
                                       ai: ai, verifier: verifier, secrets: secrets, practice: practice, helper: helper) { [weak self] in self?.onEvent(.step($0)) }
                if details.kind == .easyApply {
                    ats = .easyApply
                    result = try await EasyApplyHandler(web: web, ctx: ctx).apply()
                } else {
                    onEvent(.step("Opening the company's site"))
                    try await web.openExternalApplication()
                    Log.info("LinkedIn's Apply opened \(web.url?.absoluteString.prefix(300) ?? "nothing")")
                    landing = Self.applicationKey(web.url)
                    if let landing, let same = sameApplication(landing) {
                        Log.info("\(card.company): the same application as another posting (\(same.notes.prefix(120)))")
                        duplicate = true
                        db.upsertJob(card.id, status: same.status, title: card.title, company: card.company, location: card.location,
                                     url: card.url.absoluteString, externalURL: web.url?.absoluteString, notes: same.notes)
                        onEvent(.jobFinished(card, nil, same))
                        return
                    }
                    var reach = try await SiteRouter.reachApplication(web, step: { [weak self] in self?.onEvent(.step($0)) })
                    // A careers site that opened in another country's version (TCS's India site asks for an Indian tax
                    // ID): its version for the job's country.
                    if case .ready = reach, let local = SiteRouter.countryVersion(web.url, jobLocation: card.location) {
                        onEvent(.step("Opening the site's version for \(card.location)"))
                        Log.info("Opening the site's version for the job's country: \(local.absoluteString)")
                        try await web.load(local)
                        try await web.sleep(3)
                        reach = try await SiteRouter.reachApplication(web, step: { [weak self] in self?.onEvent(.step($0)) })
                    }
                    switch reach {
                    case .stop(let note):
                        ats = web.url.map(SiteRouter.detect) ?? .generic
                        result = await GenericHandler(web: web, ctx: ctx).stop(note)
                    case .ready(let detected):
                        ats = detected
                        onEvent(.step("Applying through \(detected.label)"))
                        result = try await SiteRouter.handler(detected).init(web: web, ctx: ctx).apply()
                    }
                    if result.externalURL == nil { result.externalURL = web.url?.absoluteString }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch RunError.signedOut {
            throw RunError.signedOut
        } catch {
            Log.error("Job \(card.id) failed: \(error.localizedDescription)")
            // The page as it was (LinkedIn's Apply that opened nothing, a dialog the app didn't know), to look into later.
            let page = await ApplicationHandler.savePage(web, paths: paths, tag: "Stopped", company: card.company, title: card.title)
            result = ApplyResult(.failedForm, notes: "Browser problem: \(error.localizedDescription.prefix(200))", evidence: page,
                                 externalURL: web.url?.absoluteString)
        }

        db.upsertJob(card.id, status: result.status, title: card.title, company: card.company, location: card.location, ats: ats,
                     url: card.url.absoluteString, externalURL: result.externalURL, notes: result.notes, evidence: result.evidence?.path,
                     countAttempt: result.status.isFailure)
        if let landing, !duplicate { opened[landing] = (card.title, result) }
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
