import Foundation

struct BackendError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Where everything lives. AA_HOME overrides the support folder (for testing next to a real setup).
struct AppPaths {
    let support: URL

    init() {
        if let custom = ProcessInfo.processInfo.environment["AA_HOME"], !custom.isEmpty {
            support = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            support = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/AutoApplicator", isDirectory: true)
        }
    }

    var appDir: URL { support.appendingPathComponent("app", isDirectory: true) }
    var tools: URL { support.appendingPathComponent("tools", isDirectory: true) }
    var logs: URL { support.appendingPathComponent("logs", isDirectory: true) }
    var screenshots: URL { logs.appendingPathComponent("screenshots", isDirectory: true) }
    var statusFile: URL { support.appendingPathComponent("install-status.txt") }
    var installLog: URL { logs.appendingPathComponent("install.log") }
    var incomingResume: URL { support.appendingPathComponent("files/.incoming-resume.pdf") }
    var python: URL { appDir.appendingPathComponent(".venv/bin/python") }
    var bundledCode: URL { Bundle.main.resourceURL!.appendingPathComponent("app", isDirectory: true) }
    var launcher: URL { bundledCode.appendingPathComponent("macos/launcher.sh") }

    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = [tools.appendingPathComponent("bin").path, "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                       "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        env["NO_COLOR"] = "1"
        env["COLUMNS"] = "92"  // fits the output box on the Home page
        for key in ["VIRTUAL_ENV", "PYTHONPATH", "PYTHONHOME"] { env.removeValue(forKey: key) }
        return env
    }

    /// An append-mode handle on a log file, for a child process's error output.
    func logHandle(_ name: String) -> FileHandle {
        let url = logs.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return FileHandle.nullDevice }
        _ = try? handle.seekToEnd()
        return handle
    }
}

/// Runs a command and returns its exit status and output (off the main thread).
enum Shell {
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String]) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.environment = environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (-1, error.localizedDescription))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }
}

/// The Python side (`python -m src.main --app-backend`), spoken to with one JSON object per line over its pipes.
final class Backend: @unchecked Sendable {
    private let process = Process()
    private let toChild = Pipe()
    private let fromChild = Pipe()
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var buffer = Data()
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var exited = false
    var onExit: (@Sendable (Int32) -> Void)?

    init(paths: AppPaths) {
        process.executableURL = paths.python
        process.arguments = ["-m", "src.main", "--app-backend"]
        process.currentDirectoryURL = paths.appDir
        process.environment = paths.environment
        process.standardInput = toChild
        process.standardOutput = fromChild
        process.standardError = paths.logHandle("app-helper.log")
    }

    func start() throws {
        fromChild.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.received(data)
        }
        process.terminationHandler = { [weak self] p in self?.terminated(p.terminationStatus) }
        try process.run()
    }

    func call(_ method: String, _ params: [String: JSON] = [:]) async throws -> JSON {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !exited else {
                lock.unlock()
                continuation.resume(throwing: BackendError(message: "The app's helper has stopped."))
                return
            }
            let id = nextID
            nextID += 1
            waiting[id] = continuation
            lock.unlock()
            var line = (try? JSONEncoder().encode(JSON.object(["id": .number(Double(id)), "method": .string(method), "params": .object(params)]))) ?? Data()
            line.append(0x0A)
            writeLock.lock()
            defer { writeLock.unlock() }
            do {
                try toChild.fileHandleForWriting.write(contentsOf: line)
            } catch {
                lock.lock()
                let pending = waiting.removeValue(forKey: id)
                lock.unlock()
                pending?.resume(throwing: BackendError(message: "Couldn't reach the app's helper."))
            }
        }
    }

    /// Closing its input makes the helper finish what it's doing and exit.
    func stop() {
        try? toChild.fileHandleForWriting.close()
    }

    private struct Reply: Decodable {
        let id: Int?
        let result: JSON?
        let error: String?
    }

    private func received(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var replies: [(CheckedContinuation<JSON, Error>, Reply)] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let reply = try? JSONDecoder().decode(Reply.self, from: line), let id = reply.id,
                  let continuation = waiting.removeValue(forKey: id) else { continue }
            replies.append((continuation, reply))
        }
        lock.unlock()
        for (continuation, reply) in replies {
            if let error = reply.error {
                continuation.resume(throwing: BackendError(message: error))
            } else {
                continuation.resume(returning: reply.result ?? .null)
            }
        }
    }

    private func terminated(_ status: Int32) {
        lock.lock()
        exited = true
        let all = waiting
        waiting = [:]
        lock.unlock()
        for continuation in all.values {
            continuation.resume(throwing: BackendError(message: "The app's helper has stopped."))
        }
        onExit?(status)
    }
}
