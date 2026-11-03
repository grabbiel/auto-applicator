import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Phase: Equatable {
    case checking   // copying the code out of the app, checking what's installed
    case welcome    // first launch: what the app does, then "Set up"
    case preparing  // downloading uv, Python and the app's components
    case failed(String)
    case starting   // starting the helper
    case setup      // first-time setup screens
    case main       // the app's home
}

enum SetupStep: String, CaseIterable, Identifiable {
    case welcome, resume, about, work, experience, jobs, email, finish

    var id: String { rawValue }
    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .resume: "Your resume"
        case .about: "About you"
        case .work: "Work & pay"
        case .experience: "Experience"
        case .jobs: "The jobs you want"
        case .email: "Email codes"
        case .finish: "Finish"
        }
    }
    var index: Int { Self.allCases.firstIndex(of: self)! }
    /// The steps shown as tabs on the "My details" page once setup is done.
    static let editable: [SetupStep] = [.resume, .about, .work, .experience, .jobs, .email]
}

enum Page: String, Hashable {
    case home, questions, results, details
}

struct Banner: Equatable {
    enum Kind { case info, ok, warn, error }
    var kind: Kind
    var text: String
    var spinning = false
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let paths = AppPaths()
    @Published var phase: Phase = .checking
    @Published var prepProgress = 0.0
    @Published var prepMessage = "Getting started…"

    @Published var draft: JSON = [:]
    @Published var options: JSON = [:]
    @Published var state: JSON = [:]
    @Published var version = ""
    @Published var errors: [String: String] = [:]
    @Published var stepMessage: String?
    @Published var saveWarnings = ""
    @Published var toast: String?
    @Published var step: SetupStep = .welcome
    @Published var furthest = 0
    @Published var dirty = false
    @Published var saving = false
    @Published var readResume = true
    @Published var uploading = false
    @Published var emailResult: Banner?
    @Published var needsHost = false
    @Published var page: Page = .home
    @Published var run: RunSession?
    @Published var helperStopped = false
    @Published var questions: [JSON] = []
    @Published var results: JSON = [:]

    private var backend: Backend?
    private var launched = false
    private var mergedVersion = 0
    private var pollTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    // MARK: derived state

    var isEdit: Bool { state["mode"].string == "edit" }
    var install: JSON { state["install"] }
    var installDone: Bool { install["done"].bool ?? false }
    var installError: String? { install["steps"].array.first { $0["status"].string == "error" }?["error"].string }
    var browserReady: Bool { install["steps"].array.first { $0["key"].string == "browser" }?["status"].string == "done" }
    var resumePresent: Bool { state["resume"]["present"].bool ?? false }
    var pendingCount: Int { state["pending_count"].int ?? 0 }
    var signedIn: Bool { state["linkedin_signed_in"].bool ?? false || state["linkedin"]["status"].string == "done" }
    var signingIn: Bool { state["linkedin"]["status"].string == "running" }
    var runActive: Bool { run?.isRunning ?? false }
    var firstName: String { draft["profile.personal.first_name"].text }

    // MARK: start-up

    func launch() {
        guard !launched else { return }
        launched = true
        Task { await checkInstall() }
    }

    private var launcherArgs: (URL, [String]) { (URL(fileURLWithPath: "/bin/bash"), [paths.launcher.path]) }

    private func checkInstall() async {
        phase = .checking
        let (bash, script) = launcherArgs
        let copy = await Shell.run(bash, script + ["install-code", paths.bundledCode.path], environment: paths.environment)
        guard copy.status == 0 else {
            phase = .failed("Auto Applicator couldn't install its files.\n\n" + copy.output)
            return
        }
        let words = await Shell.run(bash, script + ["state"], environment: paths.environment).output.split(separator: " ").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if words.first == "ready" {
            await startHelper()
        } else if words.contains("profile") {
            prepare()  // an update: no need to explain again
        } else {
            phase = .welcome
        }
    }

    /// Installs uv, Python and the app's components (macos/launcher.sh bootstrap), showing its progress.
    func prepare() {
        phase = .preparing
        prepProgress = 0.02
        prepMessage = "Getting started…"
        try? FileManager.default.removeItem(at: paths.statusFile)
        let (bash, script) = launcherArgs
        let process = Process()
        process.executableURL = bash
        process.arguments = script + ["bootstrap"]
        process.environment = paths.environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            phase = .failed("Couldn't start the installation: \(error.localizedDescription)")
            return
        }
        Task {
            var last = ("running", "")
            while true {
                let running = process.isRunning
                if let status = readStatus() { last = status }
                if !running { break }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            if process.terminationStatus == 0 && last.0 == "done" {
                await startHelper()
            } else {
                phase = .failed(last.0 == "error" && !last.1.isEmpty ? last.1 : "The installation stopped before it finished. Check your internet connection, then try again.")
            }
        }
    }

    private func readStatus() -> (String, String)? {
        guard let line = try? String(contentsOf: paths.statusFile, encoding: .utf8) else { return nil }
        let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return nil }
        prepProgress = max(prepProgress, (Double(parts[1]) ?? 0) / 100)
        prepMessage = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        return (parts[0], prepMessage)
    }

    func startHelper() async {
        phase = .starting
        helperStopped = false
        let helper = Backend(paths: paths)
        helper.onExit = { [weak self] _ in Task { @MainActor in self?.helperExited(helper) } }
        do {
            try helper.start()
            backend = helper
            let hello = try await helper.call("hello")
            version = hello["version"].text
            options = hello["options"]
            state = hello["state"]
            if dirty && draft != [:] {
                syncDraft()  // the helper restarted: keep what the user typed
            } else {
                draft = hello["draft"]
            }
            mergedVersion = state["import"]["version"].int ?? 0
            readResume = !isEdit
            furthest = isEdit ? SetupStep.allCases.count - 1 : max(furthest, 0)
            _ = try? await helper.call("install")
            if phase == .starting {
                phase = isEdit ? .main : .setup
            }
            startPolling()
        } catch {
            backend = nil
            phase = .failed("Auto Applicator couldn't start (\(error.localizedDescription)). Try again – it repairs its installation if needed.")
        }
    }

    private func helperExited(_ helper: Backend) {
        guard helper === backend else { return }
        backend = nil
        pollTask?.cancel()
        if phase == .setup || phase == .main { helperStopped = true }
    }

    func restartHelper() {
        Task { await startHelper() }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    func refresh() async {
        guard let backend, let fresh = try? await backend.call("state") else { return }
        state = fresh
        let imported = fresh["import"]
        if imported["status"].string == "done", let v = imported["version"].int, v > mergedVersion {
            mergedVersion = v
            if let merged = try? await backend.call("merge_import", ["draft": draft]) {
                draft = merged["draft"]
                dirty = true
                showToast("We filled in your details from your resume – please check them.")
            }
        }
    }

    func call(_ method: String, _ params: [String: JSON] = [:]) async -> JSON? {
        guard let backend else {
            showToast("The app's helper isn't running. Choose Restart.")
            return nil
        }
        do {
            return try await backend.call(method, params)
        } catch {
            showToast(error.localizedDescription)
            return nil
        }
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: editing the draft

    func set(_ path: String, _ value: JSON) {
        draft[path] = value
        dirty = true
        errors[path] = nil
        if path.hasPrefix("email.") {
            emailResult = nil
            if path == "email.address" { needsHost = false }
        }
    }

    func text(_ path: String) -> Binding<String> {
        Binding(get: { self.draft[path].text }, set: { self.set(path, .string($0)) })
    }

    func flag(_ path: String) -> Binding<Bool> {
        Binding(get: { self.draft[path].bool ?? false }, set: { self.set(path, .bool($0)) })
    }

    func yesNo(_ path: String) -> Binding<Bool?> {
        Binding(get: { self.draft[path].bool }, set: { if let v = $0 { self.set(path, .bool(v)) } })
    }

    func member(_ path: String, _ value: String) -> Binding<Bool> {
        Binding(get: { self.draft[path].strings.contains(value) }, set: { on in
            var list = self.draft[path].strings.filter { $0 != value }
            if on { list.append(value) }
            self.set(path, .array(list.map(JSON.string)))
        })
    }

    func time(_ path: String) -> Binding<Date> {
        Binding(get: {
            let parts = self.draft[path].text.split(separator: ":").compactMap { Int($0) }
            let comps = DateComponents(hour: parts.first ?? 9, minute: parts.count > 1 ? parts[1] : 0)
            return Calendar.current.date(from: comps) ?? Date()
        }, set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            self.set(path, .string(String(format: "%02d:%02d", c.hour ?? 9, c.minute ?? 0)))
        })
    }

    func list(_ path: String) -> [JSON] { draft[path].array }

    func append(_ path: String, _ item: JSON) { set(path, .array(list(path) + [item])) }

    func remove(_ path: String, at index: Int) {
        var items = list(path)
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        set(path, .array(items))
    }

    func choices(_ optionsPath: String, current path: String) -> [String] {
        var values = options[optionsPath].strings
        let now = draft[path].text
        if !now.isEmpty && !values.contains(now) { values.append(now) }
        return values
    }

    // MARK: setup steps

    func go(_ target: SetupStep) {
        step = target
        furthest = max(furthest, target.index)
        stepMessage = nil
        if target == .jobs && list("search.keywords").isEmpty { draft["search.keywords"] = [""] }
        syncDraft()
    }

    func back() {
        go(SetupStep.allCases[max(0, step.index - 1)])
    }

    func next() async {
        if step == .finish {
            finishSetup()
            return
        }
        guard validate(step) else { return }
        if step == .email {
            await save(thenFinish: true)
        } else {
            go(SetupStep.allCases[step.index + 1])
        }
    }

    func syncDraft() {
        guard let backend else { return }
        let current = draft
        Task { _ = try? await backend.call("set_draft", ["draft": current]) }
    }

    func validate(_ s: SetupStep) -> Bool {
        errors = [:]
        stepMessage = nil
        func need(_ path: String, _ message: String) {
            if draft[path].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors[path] = message }
        }
        switch s {
        case .resume:
            if !resumePresent {
                stepMessage = "Please add your resume (a PDF) – your applications need it."
                return false
            }
        case .about:
            need("profile.personal.first_name", "Please enter your first name.")
            need("profile.personal.last_name", "Please enter your last name.")
            need("profile.personal.email", "Please enter your email address.")
            need("profile.personal.phone", "Please enter your phone number.")
            need("profile.personal.address.city", "Please enter your city.")
        case .jobs:
            if !draft["search.keywords"].strings.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                errors["search.keywords"] = "Please enter at least one job title."
            }
        default:
            break
        }
        if !errors.isEmpty { stepMessage = "Please fill in the fields marked in red." }
        return errors.isEmpty
    }

    func save(thenFinish: Bool) async {
        guard !saving else { return }
        if !thenFinish && !validate(step) { return }
        saving = true
        defer { saving = false }
        guard let res = await call("save", ["draft": draft]) else { return }
        if res["ok"].bool == true {
            dirty = false
            state["saved"] = true
            state["mode"] = "edit"
            saveWarnings = res["warnings"].strings.joined(separator: " ")
            showToast("Saved ✓")
            if thenFinish { go(.finish) }
            await refresh()
        } else if !res["errors"].array.isEmpty {
            showServerErrors(res["errors"].array)
        } else {
            showToast(res["message"].string ?? "Couldn't save. Please try again.")
        }
    }

    private func showServerErrors(_ list: [JSON]) {
        errors = [:]
        if let first = SetupStep(rawValue: list.first?["step"].string ?? "") {
            step = first
            furthest = max(furthest, first.index)
        }
        var messages: [String] = []
        for e in list where e["step"].string == step.rawValue {
            let field = e["field"].text
            if !field.isEmpty { errors[field] = e["message"].text }
            if !messages.contains(e["message"].text) { messages.append(e["message"].text) }
        }
        stepMessage = messages.joined(separator: " ")
    }

    func finishSetup() {
        phase = .main
        page = .home
    }

    // MARK: resume

    func chooseResume() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose your resume (a PDF file)"
        panel.prompt = "Use this resume"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await useResume(url) }
        }
    }

    func useResume(_ url: URL) async {
        stepMessage = nil
        guard url.pathExtension.lowercased() == "pdf" else {
            stepMessage = "That isn't a PDF. In Word or Pages, use File › Export To › PDF, then choose that file."
            return
        }
        uploading = true
        defer { uploading = false }
        // The app reads the file (it has permission for what the user picked) and hands the helper a private copy.
        let incoming = paths.incomingResume
        do {
            try FileManager.default.createDirectory(at: incoming.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: incoming)
            try FileManager.default.copyItem(at: url, to: incoming)
        } catch {
            stepMessage = "Couldn't read that file: \(error.localizedDescription)"
            return
        }
        defer { try? FileManager.default.removeItem(at: incoming) }
        if let res = await call("resume", ["path": .string(incoming.path), "name": .string(url.lastPathComponent), "read": .bool(readResume)]),
           res["ok"].bool != true {
            stepMessage = res["message"].string ?? "Couldn't save the file."
        }
        await refresh()
    }

    func readResumeNow() {
        Task {
            _ = await call("import_resume")
            await refresh()
        }
    }

    // MARK: email

    var emailDomain: String {
        let address = draft["email.address"].text.lowercased()
        guard let at = address.lastIndex(of: "@") else { return "" }
        return String(address[address.index(after: at)...]).trimmingCharacters(in: .whitespaces)
    }

    var showHostField: Bool {
        let known = options["imap_domains"].strings.contains(emailDomain)
        return needsHost || (!draft["email.host"].text.isEmpty && !known) || (emailDomain.contains(".") && !known)
    }

    func testEmail() async {
        emailResult = Banner(kind: .info, text: "Connecting…", spinning: true)
        guard let res = await call("test_email", ["address": draft["email.address"], "password": draft["email.password"],
                                                   "host": draft["email.host"]]) else {
            emailResult = Banner(kind: .error, text: "Couldn't run the test. Please try again.")
            return
        }
        if let host = res["host"].string, draft["email.host"].text.isEmpty { draft["email.host"] = .string(host) }
        needsHost = res["needs_host"].bool ?? false
        emailResult = Banner(kind: res["ok"].bool == true ? .ok : .error, text: res["message"].text)
    }

    // MARK: actions

    func signIn() {
        Task {
            _ = await call("linkedin")
            await refresh()
        }
    }

    func retryInstall() {
        Task {
            _ = await call("install")
            await refresh()
        }
    }

    func setSchedule(_ on: Bool) {
        Task {
            if let res = await call("set_schedule", ["enabled": .bool(on)]), res["ok"].bool != true {
                showToast(res["message"].string ?? "Couldn't change the schedule.")
            } else {
                draft["search.schedule_enabled"] = .bool(on)
            }
            await refresh()
        }
    }

    func startRun(_ kind: RunSession.Kind) {
        guard !runActive else { return }
        let session = RunSession(kind: kind)
        run = session
        page = .home
        session.start(paths: paths)
    }

    func confirmLiveRun() {
        let alert = NSAlert()
        alert.messageText = "Send real applications?"
        let limit = draft["search.max_applies_per_run"].text
        alert.informativeText = "Auto Applicator will submit job applications under your name (up to \(limit.isEmpty ? "20" : limit) this time). "
            + "Check a practice run first if you haven't yet."
        alert.addButton(withTitle: "Apply now")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { startRun(.live) }
    }

    func loadQuestions() async {
        questions = (await call("pending"))?.array ?? []
    }

    /// Returns a message to show when the answer wasn't accepted.
    func answer(_ hash: String, _ text: String) async -> String? {
        guard let res = await call("answer", ["hash": .string(hash), "answer": .string(text)]) else { return "Couldn't save the answer." }
        if res["ok"].bool != true { return res["message"].text }
        await loadQuestions()
        await refresh()
        return nil
    }

    func dismiss(_ hash: String) async {
        _ = await call("dismiss", ["hash": .string(hash)])
        await loadQuestions()
        await refresh()
    }

    func loadResults() async {
        results = await call("results") ?? [:]
    }

    func open(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    // MARK: quitting

    func shouldQuit() -> Bool {
        if runActive {
            let alert = NSAlert()
            alert.messageText = "A run is still going"
            alert.informativeText = "Quitting stops it. Applications that were already sent stay sent."
            alert.addButton(withTitle: "Stop and Quit")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return false }
        }
        if dirty && phase == .main {
            let alert = NSAlert()
            alert.messageText = "Your changes aren't saved"
            alert.informativeText = "Quit anyway? Your changes on the My details page will be lost."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return false }
        }
        return true
    }

    func shutdown() {
        run?.stop()
        backend?.stop()
    }
}

/// A command run in the background (a practice run, applying, a check), with its output shown in the app.
@MainActor
final class RunSession: ObservableObject, Identifiable {
    enum Kind {
        case practice, live, checkSetup, testEmail

        var arguments: [String] {
            switch self {
            case .practice: ["--dry-run"]
            case .live: ["--live", "--yes"]
            case .checkSetup: ["--doctor"]
            case .testEmail: ["--test-imap"]
            }
        }
        var title: String {
            switch self {
            case .practice: "Practice run"
            case .live: "Applying"
            case .checkSetup: "Setup check"
            case .testEmail: "Email test"
            }
        }
        var runningText: String {
            switch self {
            case .practice: "Filling in applications without sending them…"
            case .live: "Sending applications…"
            case .checkSetup: "Checking everything…"
            case .testEmail: "Looking at your inbox…"
            }
        }
    }

    let kind: Kind
    let started = Date()
    @Published private(set) var output = ""
    @Published private(set) var isRunning = false
    @Published private(set) var exitCode: Int32?
    @Published private(set) var stopRequested = false
    private var process: Process?
    private let decoder = StreamDecoder()

    init(kind: Kind) {
        self.kind = kind
    }

    var statusText: String {
        if isRunning { return stopRequested ? "Stopping…" : kind.runningText }
        if stopRequested || exitCode == 130 { return "Stopped." }
        if exitCode == 0 { return "Finished." }
        return "Finished with a problem – see the messages below."
    }

    func start(paths: AppPaths) {
        let process = Process()
        process.executableURL = paths.python
        process.arguments = ["-m", "src.main"] + kind.arguments
        process.currentDirectoryURL = paths.appDir
        process.environment = paths.environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let decoder = self.decoder
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let text = decoder.decode(data)
            Task { @MainActor in self?.append(text) }
        }
        process.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            Task { @MainActor in self?.finished(code) }
        }
        do {
            try process.run()
            self.process = process
            isRunning = true
        } catch {
            append("Couldn't start: \(error.localizedDescription)\n")
            exitCode = -1
        }
    }

    func stop() {
        guard isRunning, let process else { return }
        stopRequested = true
        process.interrupt()  // like Ctrl-C: it closes its browser and stops cleanly
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { if process.isRunning { process.terminate() } }
    }

    private func append(_ text: String) {
        output += text
        if output.count > 400_000 { output = String(output.suffix(300_000)) }
    }

    private func finished(_ code: Int32) {
        isRunning = false
        exitCode = code
    }
}

/// Turns chunks of process output into text without splitting multi-byte characters across chunks.
final class StreamDecoder: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()

    func decode(_ data: Data) -> String {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        for cut in 0...min(3, pending.count) {
            if let text = String(data: pending.dropLast(cut), encoding: .utf8) {
                pending = Data(pending.suffix(cut))
                return text
            }
        }
        let text = String(decoding: pending, as: UTF8.self)
        pending = Data()
        return text
    }
}
