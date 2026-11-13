import Foundation

/// Where everything lives. The app bundle holds no personal data; it is all in the support folder.
///
///     ~/Library/Application Support/AutoApplicator/   (AA_HOME overrides it, e.g. for tests)
///         profile.json  settings.json  secrets.json (0600)
///         files/resume.pdf  data/jobs.db  evidence/  logs/  tools/ (Ollama, only if the larger AI is chosen)
public struct AppPaths: Sendable {
    public let home: URL

    public init(home: URL? = nil) {
        if let home {
            self.home = home
        } else if let custom = ProcessInfo.processInfo.environment["AA_HOME"], !custom.isEmpty {
            self.home = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            self.home = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/AutoApplicator", isDirectory: true)
        }
    }

    public var profileFile: URL { home.appendingPathComponent("profile.json") }
    public var settingsFile: URL { home.appendingPathComponent("settings.json") }
    public var secretsFile: URL { home.appendingPathComponent("secrets.json") }
    public var filesDir: URL { home.appendingPathComponent("files", isDirectory: true) }
    public var resumeFile: URL { filesDir.appendingPathComponent("resume.pdf") }
    public var dataDir: URL { home.appendingPathComponent("data", isDirectory: true) }
    public var database: URL { dataDir.appendingPathComponent("jobs.db") }
    public var evidenceDir: URL { home.appendingPathComponent("evidence", isDirectory: true) }
    public var coverLettersDir: URL { evidenceDir.appendingPathComponent("cover letters", isDirectory: true) }
    public var logsDir: URL { home.appendingPathComponent("logs", isDirectory: true) }
    public var toolsDir: URL { home.appendingPathComponent("tools", isDirectory: true) }

    // Files from version 0.3 (Python), read once to carry the user's setup over.
    public var legacyProfile: URL { home.appendingPathComponent("profile.yaml") }
    public var legacyConfig: URL { home.appendingPathComponent("config.yaml") }
    public var legacyEnv: URL { home.appendingPathComponent(".env") }

    @discardableResult
    public func ensure() -> AppPaths {
        let fm = FileManager.default
        for dir in [home, filesDir, dataDir, evidenceDir, coverLettersDir, logsDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        return self
    }
}

/// A small append-only log in logs/app.log (rotated at 2 MB). Messages never contain passwords.
public enum Log {
    private static let queue = DispatchQueue(label: "aa.log")
    nonisolated(unsafe) private static var url: URL?

    public static func configure(_ paths: AppPaths) {
        queue.sync {
            url = paths.logsDir.appendingPathComponent("app.log")
            if let url, let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 2_000_000 {
                let old = url.deletingPathExtension().appendingPathExtension("1.log")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
            }
        }
    }

    public static func info(_ message: @autoclosure () -> String) { write("INFO", message()) }
    public static func warn(_ message: @autoclosure () -> String) { write("WARN", message()) }
    public static func error(_ message: @autoclosure () -> String) { write("ERROR", message()) }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func write(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) \(level) \(message)\n"
        queue.async {
            #if DEBUG
            FileHandle.standardError.write(Data(line.utf8))
            #endif
            guard let url else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

extension FileManager {
    /// Writes data atomically with the given permissions (the support folder holds personal data).
    public func writeSecurely(_ data: Data, to url: URL, permissions: Int = 0o600) throws {
        try createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        try setAttributes([.posixPermissions: permissions], ofItemAtPath: tmp.path)
        if fileExists(atPath: url.path) {
            _ = try replaceItemAt(url, withItemAt: tmp)
        } else {
            try moveItem(at: tmp, to: url)
        }
    }
}
