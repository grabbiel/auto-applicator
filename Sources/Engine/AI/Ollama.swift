import Foundation

/// A model served by Ollama (optional: for Macs without Apple Intelligence, or people who prefer a bigger model).
final class OllamaModel: LanguageModel, @unchecked Sendable {
    let baseURL: URL
    let model: String
    let numCtx: Int
    var displayName: String { "Ollama · \(model)" }
    var promptBudget: Int { numCtx * 3 - 3000 }

    init(baseURL: URL, model: String, numCtx: Int = 8192) {
        self.baseURL = baseURL
        self.model = model
        self.numCtx = numCtx
    }

    private func chat(_ instructions: String, _ prompt: String, format: Any?) async throws -> String {
        var body: [String: Any] = [
            "model": model, "stream": false, "keep_alive": "15m",
            "messages": [["role": "system", "content": instructions], ["role": "user", "content": prompt]],
            "options": ["temperature": 0, "num_ctx": numCtx],
        ]
        if let format { body["format"] = format }
        var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"), timeoutInterval: 240)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw AIError.unavailable("Can't reach Ollama (\(error.localizedDescription)).")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let err = json?["error"] as? String {
            if err.contains("not found") { throw AIError.unavailable("The model \(model) isn't downloaded yet.") }
            throw AIError.server(err)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200, let message = json?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIError.server("Ollama returned an unexpected answer.")
        }
        return content
    }

    func generate(instructions: String, prompt: String, schema: AISchema) async throws -> [String: Any] {
        let order = schema.orderedKeys.isEmpty ? "" : "\nReturn JSON with the keys in this order: \(schema.orderedKeys.joined(separator: ", "))."
        return try parseJSONObject(try await chat(instructions + order, prompt, format: schema.jsonSchema()))
    }

    func generateText(instructions: String, prompt: String) async throws -> String {
        try await chat(instructions, prompt, format: nil)
    }
}

/// Finds, installs, starts and stops Ollama. A server the user already runs is reused and left alone; otherwise the
/// app starts its own on a private port under the supervisor, so it stops when the app quits.
public final class OllamaManager: @unchecked Sendable {
    public static let defaultPort = 11434
    public static let privatePort = 11435
    static let downloadURL = URL(string: "https://github.com/ollama/ollama/releases/latest/download/ollama-darwin.tgz")!

    let paths: AppPaths
    private let lock = NSLock()
    private var process: Process?
    private var activeURL: URL?

    public init(paths: AppPaths) { self.paths = paths }

    static func url(_ port: Int) -> URL { URL(string: "http://127.0.0.1:\(port)")! }

    public var bundledDir: URL { paths.toolsDir.appendingPathComponent("ollama") }

    /// The `ollama` program: the app's own copy, the Ollama app, or Homebrew.
    public func binary() -> URL? {
        let fm = FileManager.default
        var candidates = [
            "/Applications/Ollama.app/Contents/Resources/ollama",
            "/opt/homebrew/bin/ollama",
            "/usr/local/bin/ollama",
            NSHomeDirectory() + "/Applications/Ollama.app/Contents/Resources/ollama",
        ]
        if let found = fm.enumerator(atPath: bundledDir.path)?.compactMap({ $0 as? String }).filter({ ($0 as NSString).lastPathComponent == "ollama" })
            .sorted(by: { $0.count < $1.count }).first {
            candidates.insert(bundledDir.appendingPathComponent(found).path, at: 0)
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    public var isInstalled: Bool { binary() != nil }

    static func ping(_ url: URL) async -> Bool {
        var req = URLRequest(url: url.appendingPathComponent("api/version"), timeoutInterval: 2)
        req.httpMethod = "GET"
        guard let (_, response) = try? await URLSession.shared.data(for: req) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Makes sure a server answers and returns its address.
    public func ensureRunning() async throws -> URL {
        if let url = lock.withLock({ activeURL }), await Self.ping(url) { return url }
        if await Self.ping(Self.url(Self.defaultPort)) {
            lock.withLock { activeURL = Self.url(Self.defaultPort) }
            return Self.url(Self.defaultPort)
        }
        guard let exe = binary() else { throw AIError.unavailable("Ollama isn't installed.") }
        let url = Self.url(Self.privatePort)
        if !(await Self.ping(url)) {
            let env = [
                "OLLAMA_HOST": "127.0.0.1:\(Self.privatePort)",
                // Flash attention and an 8-bit cache roughly halve the memory the context uses.
                "OLLAMA_FLASH_ATTENTION": "1", "OLLAMA_KV_CACHE_TYPE": "q8_0",
            ]
            let p = try Supervisor.launch(exe, arguments: ["serve"], environment: env, log: paths.logsDir.appendingPathComponent("ollama.log"))
            lock.withLock { process = p }
            for _ in 0..<60 {
                if await Self.ping(url) { break }
                if !p.isRunning { throw AIError.unavailable("Ollama stopped while starting. See logs/ollama.log.") }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            guard await Self.ping(url) else { throw AIError.unavailable("Ollama didn't start in time.") }
        }
        lock.withLock { activeURL = url }
        return url
    }

    /// Stops the server the app started (a server the user runs is left alone).
    public func stop() {
        lock.withLock {
            if let p = process { Supervisor.stop(p) }
            process = nil
            activeURL = nil
        }
    }

    public func installedModels() async throws -> [String] {
        let url = try await ensureRunning()
        let (data, _) = try await URLSession.shared.data(from: url.appendingPathComponent("api/tags"))
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return ((json?["models"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
    }

    public func hasModel(_ name: String) async -> Bool {
        guard let names = try? await installedModels() else { return false }
        return names.contains(name) || (!name.contains(":") && names.contains(name + ":latest"))
    }

    /// Downloads a model, reporting progress from 0 to 1.
    public func pull(_ model: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let url = try await ensureRunning()
        var req = URLRequest(url: url.appendingPathComponent("api/pull"), timeoutInterval: 3600)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        let (bytes, _) = try await URLSession.shared.bytes(for: req)
        var layers: [String: (Double, Double)] = [:]
        for try await line in bytes.lines {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            if let err = event["error"] as? String { throw AIError.server("Couldn't download the AI model: \(err)") }
            if let digest = event["digest"] as? String, let total = event["total"] as? Double, total > 0 {
                layers[digest] = ((event["completed"] as? Double) ?? 0, total)
                let done = layers.values.reduce(0) { $0 + $1.0 }, all = layers.values.reduce(0) { $0 + $1.1 }
                progress(all > 0 ? done / all : 0)
            }
            if event["status"] as? String == "success" { progress(1); return }
        }
        guard await hasModel(model) else { throw AIError.server("The download stopped before finishing. Try again to continue it.") }
    }

    /// Downloads the official Ollama command-line build into the app's tools folder.
    public func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        paths.ensure()
        let archive = paths.toolsDir.appendingPathComponent("ollama-darwin.tgz")
        let delegate = DownloadProgress(progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (tmp, response) = try await session.download(from: Self.downloadURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AIError.server("The Ollama download failed.") }
        let fm = FileManager.default
        try? fm.removeItem(at: archive)
        try fm.moveItem(at: tmp, to: archive)
        try? fm.removeItem(at: bundledDir)
        try fm.createDirectory(at: bundledDir, withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", bundledDir.path]
        try tar.run()
        tar.waitUntilExit()
        try? fm.removeItem(at: archive)
        guard tar.terminationStatus == 0, binary() != nil else { throw AIError.server("The Ollama download looks incomplete. Try again.") }
    }

    /// qwen2.5:7b (about 5 GB in memory) suits 16 GB Macs; 32 GB or more can afford the 14b model.
    public static var recommendedModel: String {
        ProcessInfo.processInfo.physicalMemory >= 32 << 30 ? "qwen2.5:14b" : "qwen2.5:7b"
    }

    func model(named name: String) async throws -> LanguageModel {
        let url = try await ensureRunning()
        let ctx = ProcessInfo.processInfo.physicalMemory >= 24 << 30 ? 12288 : 8192
        return OllamaModel(baseURL: url, model: name, numCtx: ctx)
    }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
