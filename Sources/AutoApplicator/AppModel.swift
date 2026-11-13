import AppKit
import Engine
import SwiftUI
import WebKit

enum AppPage: String, CaseIterable, Identifiable {
    case home, live, inbox, applications, knowledge, profile, search, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Today"
        case .live: "Live"
        case .inbox: "Questions"
        case .applications: "Applications"
        case .knowledge: "What it knows"
        case .profile: "Profile"
        case .search: "Job search"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: "sun.max"
        case .live: "dot.radiowaves.left.and.right"
        case .inbox: "questionmark.bubble"
        case .applications: "tray.full"
        case .knowledge: "brain"
        case .profile: "person.crop.circle"
        case .search: "magnifyingglass"
        case .settings: "gearshape"
        }
    }
}

enum AIState: Equatable {
    case checking
    case ready(String)
    case needsSetup(String)
    case working(String, Double?)
    case failed(String)

    var isReady: Bool { if case .ready = self { true } else { false } }
}

enum LinkedInState { case unknown, signedIn, signedOut }

struct Outcome: Identifiable {
    let id = UUID()
    var card: JobCard
    var ats: ATSType?
    var result: ApplyResult
    var at = Date()
}

struct DayActivity: Identifiable {
    var day: Date
    var sent: Int
    var prepared: Int
    var id: Date { day }
}

/// Something that stops a run from starting, with the place to fix it.
struct Blocker: Identifiable {
    var id: String
    var message: String
    var fixTitle: String
    var fix: @MainActor () -> Void
}

/// The app's state and everything the screens can do. One instance, owned by the app delegate.
@MainActor @Observable
final class AppModel {
    let paths: AppPaths
    @ObservationIgnored let store: Store
    @ObservationIgnored let db: Database
    @ObservationIgnored let ollama: OllamaManager

    var profile: Profile { didSet { if profile != oldValue { scheduleSave() } } }
    var settings: Engine.Settings { didSet { if settings != oldValue { scheduleSave() } } }
    var secrets: Secrets { didSet { if secrets != oldValue { scheduleSave() } } }
    var resumePresent: Bool

    var page: AppPage = .home
    var profileSection: ProfileSection = .about
    var onboardingStep: OnboardingStep = .welcome
    var tourStep: Int?
    /// What the search box sent to Applications and What it knows (each page also edits it in its own field).
    var applicationsQuery = ""
    var knowledgeQuery = ""
    var toast: Toast?

    // the current run
    var isRunning = false
    var runPractice = true
    var runPhase = ""
    var currentJob: JobCard?
    var currentSteps: [String] = []
    var outcomes: [Outcome] = []
    var warnings: [String] = []
    var lastSummary: RunSummary?
    var runError: String?
    var runStartedAt: Date?
    var livePreview: NSImage?
    var liveURL: String = ""
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    /// Opened by the daily schedule: quit when the run ends (unless the user starts using the window).
    @ObservationIgnored var scheduledLaunch = false

    // what it has learned
    var pending: [PendingQuestion] = []
    var jobs: [JobRecord] = []
    var facts: [Fact] = []
    var learned: [CachedAnswer] = []
    var runs: [RunRecord] = []
    var activity: [DayActivity] = []
    var weekCounts: [JobStatus: Int] = [:]

    // resume reading
    var resumeStatus: String?
    var resumeError: String?
    var resumeFound: String?

    // AI
    var aiState: AIState = .checking
    @ObservationIgnored private(set) var ai: AIService?

    // LinkedIn
    var linkedInState: LinkedInState = .unknown
    var showSignIn = false

    // email codes
    var emailTest: (ok: Bool, message: String)?
    var emailTesting = false

    // cloud browser (see Cloud.swift)
    @ObservationIgnored let cloudConfig: CloudConfig?
    @ObservationIgnored private(set) var cloudAccount: CloudAccount?
    var cloudBusy: String?
    var cloudTest: CloudTest?
    /// The current (or last) run uses the cloud browser.
    var runInCloud = false
    /// The browser the current run drives (the built-in one or a cloud session).
    @ObservationIgnored private var runAgent: WebAgent?
    @ObservationIgnored private var didShutdown = false

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var installedSchedule: Schedule?
    @ObservationIgnored private var webAgent: WebAgent?

    init(paths: AppPaths = AppPaths()) {
        paths.ensure()
        Log.configure(paths)
        self.paths = paths
        // Stop any helper an earlier session left behind before anything might reuse it.
        Supervisor.registry = paths.logsDir.appendingPathComponent("helpers", isDirectory: true)
        Supervisor.reapOrphans()
        store = Store(paths: paths)
        let migration = LegacyMigration.runIfNeeded(paths: paths)
        db = Self.openDatabase(paths)
        ollama = OllamaManager(paths: paths)
        profile = store.loadProfile() ?? Profile()
        settings = store.loadSettings()
        secrets = store.loadSecrets()
        resumePresent = store.resumePresent
        cloudConfig = CloudConfig.load(paths: paths)
        if secrets.portalPassword.isEmpty {
            secrets.portalPassword = Secrets.generatePortalPassword()
            try? store.save(secrets)
        }
        if let cloudConfig {
            cloudAccount = CloudAccount(config: cloudConfig, refreshToken: secrets.cloudRefreshToken) { [weak self] token in
                Task { @MainActor in self?.cloudSignInChanged(token) }
            }
        }
        if migration.migrated && settings.schedule.enabled { applySchedule() }
        installedSchedule = Scheduler.isInstalled ? settings.schedule : nil
        // Set up before (or carried over from 0.3) but never shown the tour.
        if settings.setupComplete && !settings.tourComplete { tourStep = 0 }
        refreshData()
        Log.info("App started (\(Bundle.main.bundleIdentifier ?? "no bundle"))")
    }

    static func openDatabase(_ paths: AppPaths) -> Database {
        if let db = try? Database(paths: paths) { return db }
        // A damaged file is set aside so the app still opens.
        let aside = paths.database.deletingLastPathComponent().appendingPathComponent("jobs-damaged-\(Int(Date().timeIntervalSince1970)).db")
        try? FileManager.default.moveItem(at: paths.database, to: aside)
        Log.error("The database couldn't be opened; moved it to \(aside.lastPathComponent)")
        return try! Database(paths: paths)
    }

    var web: WebAgent {
        if let webAgent { return webAgent }
        let w = WebAgent()
        webAgent = w
        return w
    }

    // MARK: - saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        do {
            try store.save(profile)
            try store.save(settings)
            try store.save(secrets)
        } catch {
            show("Couldn't save: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill", tone: .red)
        }
    }

    func show(_ message: String, symbol: String = "checkmark.circle.fill", tone: Tone = .green) {
        let t = Toast(message: message, symbol: symbol, tone: tone)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { toast = t }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.2))
            if self?.toast?.id == t.id { withAnimation(.easeOut(duration: 0.25)) { self?.toast = nil } }
        }
    }

    // MARK: - data

    func refreshData() {
        pending = db.listPending()
        jobs = db.recentJobs(limit: 500)
        facts = db.facts()
        learned = db.cacheEntries()
        runs = db.recentRuns(limit: 30)
        activity = db.dailyActivity(days: 14).map { DayActivity(day: $0.day, sent: $0.sent, prepared: $0.prepared) }
        weekCounts = db.statusCounts(since: Calendar.current.date(byAdding: .day, value: -7, to: Date()))
        NSApp?.dockTile.badgeLabel = pending.isEmpty ? nil : "\(pending.count)"
    }

    var knowledge: KnowledgeReport {
        KnowledgeReport(profile: profile, resumePresent: resumePresent, emailConfigured: secrets.emailConfigured,
                        learnedAnswers: learned.filter(\.learnedFromUser).count, facts: facts.count, pending: pending.count)
    }

    var firstName: String {
        let n = profile.personal.preferredName.trimmed
        return n.isEmpty ? profile.personal.firstName.trimmed : n
    }

    // MARK: - questions and memory

    func answer(_ q: PendingQuestion, with text: String) {
        let answer = text.trimmed
        guard !answer.isEmpty else { return }
        db.resolvePending(q.hash, answer: answer)
        if let skill = Memory.learnedSkill(question: q.question, answer: answer) {
            profile.experienceYears[skill.skill] = skill.years
        }
        refreshData()
        show("Learned. It'll use that answer from now on.", symbol: "brain")
    }

    func dismiss(_ q: PendingQuestion) {
        db.dismissPending(q.hash)
        refreshData()
    }

    func edit(_ a: CachedAnswer, answer: String) {
        db.cachePut(a.hash, question: a.question, fieldType: a.fieldType, options: a.options, answer: answer.trimmed, source: "edited")
        refreshData()
        show("Answer updated.")
    }

    func forget(_ a: CachedAnswer) {
        db.cacheDelete(a.hash)
        refreshData()
    }

    func addFact(_ text: String) {
        guard !text.trimmed.isEmpty else { return }
        db.addFact(text)
        refreshData()
        show("Got it. It'll keep that in mind.", symbol: "brain")
    }

    func updateFact(_ f: Fact, text: String) {
        if text.trimmed.isEmpty { db.deleteFact(f.id) } else { db.updateFact(f.id, text: text) }
        refreshData()
    }

    func deleteFact(_ f: Fact) {
        db.deleteFact(f.id)
        refreshData()
    }

    func removeJob(_ job: JobRecord) {
        db.deleteJob(job.id)
        refreshData()
    }

    // MARK: - resume

    func importResume(_ url: URL) async {
        resumeError = nil
        resumeFound = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try store.importResume(from: url)
        } catch {
            resumeError = error.localizedDescription
            return
        }
        resumePresent = true
        await readResume()
    }

    /// Reads the saved resume and fills in whatever the profile doesn't have yet (never overwrites).
    func readResume() async {
        resumeStatus = "Reading your resume…"
        let ai = await ensureAI()
        let facts = await ResumeReader.read(paths.resumeFile, ai: ai) { [weak self] message in
            Task { @MainActor in if self?.resumeStatus != nil { self?.resumeStatus = message } }
        }
        resumeStatus = nil
        guard let facts else {
            resumeError = "Couldn't read text from this PDF (it may be a scanned image). You can type your details on the next steps."
            return
        }
        var p = profile
        facts.merge(into: &p)
        profile = p
        var found: [String] = []
        if !facts.firstName.isEmpty { found.append("your name") }
        if !facts.email.isEmpty || !facts.phone.isEmpty { found.append("contact details") }
        if !facts.workHistory.isEmpty { found.append("\(facts.workHistory.count) job\(facts.workHistory.count == 1 ? "" : "s")") }
        if !facts.education.isEmpty { found.append("\(facts.education.count) school\(facts.education.count == 1 ? "" : "s")") }
        if !facts.skills.isEmpty { found.append("\(facts.skills.count) skills") }
        resumeFound = found.isEmpty ? "Saved. Fill in your details on the next steps." : "Found " + ListFormatter.localizedString(byJoining: found) + "."
    }

    // MARK: - AI

    /// The AI service, starting it if needed. nil when no engine is available (runs still work from saved answers).
    @discardableResult
    func ensureAI() async -> AIService? {
        if let ai { return ai }
        if case .working = aiState { return nil }
        aiState = .checking
        do {
            let service = try await AIService.make(settings: settings.ai, ollama: ollama)
            ai = service
            aiState = .ready(service.displayName)
            return service
        } catch {
            aiState = ollama.isInstalled || settings.ai.engine == .ollama
                ? .failed(error.localizedDescription)
                : .needsSetup(AppleIntelligence.status.explanation)
            return nil
        }
    }

    func resetAI() {
        ai = nil
        ollama.stop()
        aiState = .checking
        Task { await ensureAI() }
    }

    var ollamaDownloadSize: String { OllamaManager.recommendedModel.contains("14b") ? "about 9 GB" : "about 5 GB" }

    /// Downloads Ollama and the recommended model (for Macs without Apple Intelligence).
    func setUpOllama() async {
        let model = OllamaManager.recommendedModel
        do {
            if !ollama.isInstalled {
                aiState = .working("Downloading the AI runner (step 1 of 2)", 0)
                try await ollama.install { [weak self] p in Task { @MainActor in self?.progress("Downloading the AI runner (step 1 of 2)", p) } }
            }
            aiState = .working("Downloading the AI model (step 2 of 2)", 0)
            try await ollama.pull(model) { [weak self] p in Task { @MainActor in self?.progress("Downloading the AI model (step 2 of 2)", p) } }
            settings.ai.engine = .ollama
            settings.ai.ollamaModel = model
            ai = nil
            aiState = .checking
            await ensureAI()
        } catch {
            aiState = .failed(error.localizedDescription)
        }
    }

    private func progress(_ label: String, _ p: Double) {
        if case .working(_, let old) = aiState, let old, abs(old - p) < 0.004 && p < 1 { return }
        aiState = .working(label, p)
    }

    // MARK: - LinkedIn

    func refreshLinkedIn() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let ok = cookies.contains { $0.name == "li_at" && $0.domain.hasSuffix("linkedin.com") && ($0.expiresDate ?? .distantFuture) > Date() }
        linkedInState = ok ? .signedIn : .signedOut
    }

    func signOutOfLinkedIn() async {
        await WebAgent.clearWebsiteData()
        linkedInState = .signedOut
        show("Signed out of LinkedIn.")
    }

    // MARK: - email codes

    func testEmail() async {
        emailTesting = true
        emailTest = nil
        defer { emailTesting = false }
        if secrets.imapHost.isEmpty, let host = EmailProviders.host(for: secrets.imapUser) { secrets.imapHost = host }
        do {
            let n = try await EmailVerifier(secrets: secrets, ai: nil).testConnection()
            emailTest = (true, "Connected. It can read your inbox (\(n) unread).")
        } catch {
            emailTest = (false, error.localizedDescription)
        }
    }

    // MARK: - schedule

    func applySchedule() {
        let schedule = settings.schedule
        guard installedSchedule != schedule || Scheduler.isInstalled != schedule.enabled else { return }
        installedSchedule = schedule
        if schedule.enabled {
            do {
                try Scheduler.install(schedule, paths: paths)
                Notifier.requestPermission()
            } catch {
                show(error.localizedDescription, symbol: "exclamationmark.triangle.fill", tone: .red)
            }
        } else {
            Scheduler.remove()
        }
    }

    var nextScheduledRun: Date? {
        let s = settings.schedule
        guard s.enabled else { return nil }
        let cal = Calendar.current
        var day = Date()
        for _ in 0..<8 {
            if let t = cal.date(bySettingHour: s.hour, minute: s.minute, second: 0, of: day), t > Date(),
               !s.weekdaysOnly || !cal.isDateInWeekend(t) { return t }
            day = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: day))!
        }
        return nil
    }

    /// The link the launchd agent opens. Only a link with this Mac's token starts a run.
    func handle(url: URL) {
        guard url.scheme == Scheduler.urlScheme, url.host == "scheduled-run" else { return }
        let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "token" }?.value
        guard token == settings.schedule.token, settings.schedule.enabled else {
            Log.warn("Ignored a run link with the wrong token")
            return
        }
        guard settings.setupComplete, !isRunning else { return }
        Log.info("Scheduled run starting")
        startRun(practice: settings.practiceMode)
    }

    // MARK: - runs

    var blockers: [Blocker] {
        var list: [Blocker] = []
        if !profile.isComplete {
            list.append(Blocker(id: "profile", message: "Add your name, email and phone.", fixTitle: "Open Profile") { [weak self] in self?.page = .profile })
        }
        if !resumePresent {
            list.append(Blocker(id: "resume", message: "Add your resume (PDF).", fixTitle: "Add resume") { [weak self] in self?.page = .profile })
        }
        if settings.search.cleanKeywords.isEmpty {
            list.append(Blocker(id: "titles", message: "Choose at least one job title to look for.", fixTitle: "Job search") { [weak self] in self?.page = .search })
        }
        if linkedInState == .signedOut {
            list.append(Blocker(id: "linkedin", message: "Sign in to LinkedIn.", fixTitle: "Sign in") { [weak self] in self?.showSignIn = true })
        }
        if settings.cloudBrowser && cloudAvailable && !cloudSignedIn {
            list.append(Blocker(id: "cloud", message: "Sign in to the cloud browser again (or turn it off).", fixTitle: "Settings") { [weak self] in
                self?.page = .settings
            })
        }
        return list
    }

    func startRun(practice: Bool) {
        guard !isRunning else { return }
        saveNow()
        runError = nil
        outcomes = []
        warnings = []
        currentJob = nil
        currentSteps = []
        lastSummary = nil
        livePreview = nil
        runPractice = practice
        runInCloud = usesCloud
        runStartedAt = Date()
        runPhase = "Getting ready"
        isRunning = true
        page = .live
        // Keep the Mac awake while applying (and its display, so pages in the built-in browser stay "visible" to WebKit).
        let activity = ProcessInfo.processInfo.beginActivity(
            options: runInCloud ? [.userInitiated, .idleSystemSleepDisabled] : [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "Applying to jobs")
        startPreview()
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.ensureAI()
            var browser: WebAgent?
            do {
                let agent = try await self.makeRunBrowser()
                browser = agent
                self.runAgent = agent
                let runner = JobRunner(paths: self.paths, db: self.db, web: agent, ai: self.ai, practice: practice) { [weak self] event in
                    self?.handle(event)
                }
                let summary = try await runner.run()
                self.lastSummary = summary
                self.finishNotification(summary)
            } catch RunError.signedOut {
                await self.refreshLinkedIn()
                self.runError = self.runInCloud && self.linkedInState == .signedIn
                    ? "LinkedIn asked the cloud browser to sign in again. Sign out of LinkedIn and back in (Settings › LinkedIn), then try again, or turn the cloud browser off."
                    : RunError.signedOut.localizedDescription
                if !self.runInCloud { self.linkedInState = .signedOut }
            } catch {
                self.runError = error.localizedDescription
            }
            if let browser, browser.cloud != nil {
                // Save its cookies and end the session, even when the run was stopped (a new task isn't cancelled).
                self.runPhase = "Closing the cloud browser"
                await Task { await browser.finish() }.value
            }
            self.runAgent = nil
            ProcessInfo.processInfo.endActivity(activity)
            self.isRunning = false
            self.currentJob = nil
            self.previewTask?.cancel()
            self.runTask = nil
            self.refreshData()
            if let error = self.runError, self.scheduledLaunch { Notifier.post("Auto Applicator couldn't run", error) }
            if self.scheduledLaunch { NSApp.terminate(nil) }
        }
    }

    func stopRun() {
        runPhase = "Stopping…"
        runTask?.cancel()
        (runAgent ?? webAgent)?.stopLoading()
    }

    /// Ends the run and waits (briefly) for it to record what it did.
    func stopRunAndWait(timeout: TimeInterval = 4) async {
        guard let task = runTask else { return }
        stopRun()
        let deadline = Date().addingTimeInterval(timeout)
        while runTask != nil && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        _ = task
    }

    private func handle(_ event: RunEvent) {
        switch event {
        case .phase(let text):
            runPhase = text
        case .jobStarted(let card):
            withAnimation(.snappy) {
                currentJob = card
                currentSteps = ["Opened the job posting"]
            }
        case .step(let text):
            withAnimation(.snappy) {
                if currentSteps.last != text { currentSteps.append(text) }
            }
        case .jobFinished(let card, let ats, let result):
            withAnimation(.snappy) {
                outcomes.insert(Outcome(card: card, ats: ats, result: result), at: 0)
                if currentJob?.id == card.id { currentJob = nil }
            }
            refreshData()
        case .warning(let text):
            warnings.append(text)
        }
    }

    private func finishNotification(_ s: RunSummary) {
        guard scheduledLaunch || !NSApp.isActive else { return }
        Notifier.post(s.practice ? "Practice run finished" : "Applications sent", s.headline)
    }

    /// A picture of the automated browser twice a second, for the Live page (the browser itself stays hidden).
    private func startPreview() {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.page == .live, let agent = self.runAgent ?? self.webAgent, NSApp.isActive || NSApp.windows.contains(where: \.isVisible) {
                    if let image = await agent.snapshot() { self.livePreview = image }
                    self.liveURL = agent.url?.host ?? ""
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    // MARK: - setup

    func finishOnboarding() {
        settings.setupComplete = true
        saveNow()
        page = .home
        if !settings.tourComplete { tourStep = 0 }
        Notifier.requestPermission()
    }

    func restartSetup() {
        onboardingStep = .welcome
        settings.setupComplete = false
    }

    // MARK: - quitting

    /// Ends everything the app started: the browser, the AI server, any helper process.
    func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        saveNow()
        previewTask?.cancel()
        runTask?.cancel()
        runAgent?.close()  // a cloud session is stopped before the app exits
        webAgent?.close()
        ollama.stop()
        Supervisor.terminateAll(timeout: 2)
        Log.info("App quit")
    }
}
