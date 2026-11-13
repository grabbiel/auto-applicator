import Foundation

/// Loads and saves profile.json, settings.json and secrets.json. Writes are atomic and private (0600).
public struct Store: Sendable {
    public let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return e
    }()

    public func loadProfile() -> Profile? {
        guard let data = try? Data(contentsOf: paths.profileFile) else { return nil }
        do {
            return try JSONDecoder().decode(Profile.self, from: data)
        } catch {
            Log.error("profile.json couldn't be read: \(error)")
            return nil
        }
    }

    public func save(_ profile: Profile) throws {
        try FileManager.default.writeSecurely(try Self.encoder.encode(profile), to: paths.profileFile)
    }

    public func loadSettings() -> Settings {
        guard let data = try? Data(contentsOf: paths.settingsFile) else { return Settings() }
        return (try? JSONDecoder().decode(Settings.self, from: data)) ?? Settings()
    }

    public func save(_ settings: Settings) throws {
        try FileManager.default.writeSecurely(try Self.encoder.encode(settings), to: paths.settingsFile)
    }

    public func loadSecrets() -> Secrets {
        guard let data = try? Data(contentsOf: paths.secretsFile) else { return Secrets() }
        return (try? JSONDecoder().decode(Secrets.self, from: data)) ?? Secrets()
    }

    public func save(_ secrets: Secrets) throws {
        try FileManager.default.writeSecurely(try Self.encoder.encode(secrets), to: paths.secretsFile)
    }

    public var resumePresent: Bool { FileManager.default.fileExists(atPath: paths.resumeFile.path) }

    /// Copies the chosen PDF into the support folder (the app keeps its own copy to attach to applications).
    public func importResume(from url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.starts(with: Array("%PDF".utf8)) else { throw StoreError.notPDF }
        guard data.count <= 25 * 1_048_576 else { throw StoreError.tooBig }
        try FileManager.default.writeSecurely(data, to: paths.resumeFile)
    }
}

public enum StoreError: LocalizedError {
    case notPDF, tooBig
    public var errorDescription: String? {
        switch self {
        case .notPDF: "That file isn't a PDF. In Word or Pages, choose File › Export To › PDF, then pick that file."
        case .tooBig: "That file is over 25 MB. Please choose a smaller PDF."
        }
    }
}

/// Carries a version 0.3 setup (profile.yaml, config.yaml, .env, the Python app) over to this version, once.
public enum LegacyMigration {
    public struct Result: Sendable {
        public var migrated = false
        public var scheduleWasOn = false
    }

    public static func runIfNeeded(paths: AppPaths) -> Result {
        let fm = FileManager.default
        var result = Result()
        let store = Store(paths: paths)
        guard !fm.fileExists(atPath: paths.profileFile.path), fm.fileExists(atPath: paths.legacyProfile.path) else {
            return result
        }
        Log.info("Migrating the 0.3 setup")
        do {
            let text = try String(contentsOf: paths.legacyProfile, encoding: .utf8)
            let tree = try YAML.parse(text)
            let data = try JSONSerialization.data(withJSONObject: tree)
            var profile = try JSONDecoder().decode(Profile.self, from: data)
            profile.files.resumePDF = "files/resume.pdf"
            try store.save(profile)
            result.migrated = true
        } catch {
            Log.error("Couldn't migrate profile.yaml: \(error)")
            return result
        }

        var settings = Settings()
        settings.setupComplete = true
        if let text = try? String(contentsOf: paths.legacyConfig, encoding: .utf8), let tree = try? YAML.parse(text) as? [String: Any] {
            settings = settingsFromLegacy(tree)
        }
        let oldAgent = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/com.local.auto-applicator.plist")
        if fm.fileExists(atPath: oldAgent.path) {
            result.scheduleWasOn = true
            settings.schedule.enabled = true
            let launchctl = Process()
            launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            launchctl.arguments = ["bootout", "gui/\(getuid())/com.local.auto-applicator"]
            try? launchctl.run()
            launchctl.waitUntilExit()
            try? fm.removeItem(at: oldAgent)
        }
        try? store.save(settings)

        if let env = try? String(contentsOf: paths.legacyEnv, encoding: .utf8) {
            try? store.save(secretsFromEnv(env))
        }

        // Keep the old files for reference; remove the old Python app, its browser profile and status file (GBs).
        let archive = paths.home.appendingPathComponent("previous-version", isDirectory: true)
        try? fm.createDirectory(at: archive, withIntermediateDirectories: true)
        for url in [paths.legacyProfile, paths.legacyConfig, paths.legacyEnv] where fm.fileExists(atPath: url.path) {
            try? fm.moveItem(at: url, to: archive.appendingPathComponent(url.lastPathComponent))
        }
        for junk in ["app", "data/chrome_profile", "install-status.txt", "tools/bin"] {
            try? fm.removeItem(at: paths.home.appendingPathComponent(junk))
        }
        return result
    }

    static func settingsFromLegacy(_ tree: [String: Any]) -> Settings {
        var s = Settings()
        s.setupComplete = true
        let queries = tree["search_queries"] as? [[String: Any]] ?? []
        s.search.keywords = queries.compactMap { $0["keywords"].map { "\($0)" } }
        if let q = queries.first {
            s.search.location = q["location"] as? String ?? s.search.location
            s.search.workplace = (q["workplace_type"] as? [Any] ?? []).compactMap { WorkplaceType(rawValue: "\($0)") }
            s.search.levels = (q["experience_level"] as? [Any] ?? []).compactMap { ExperienceLevel(rawValue: "\($0)") }
            s.search.datePosted = (q["date_posted"] as? String).flatMap(DatePosted.init) ?? .pastWeek
            s.search.includeExternal = q["include_external"] as? Bool ?? false
            s.search.maxPages = q["max_pages"] as? Int ?? 3
        }
        if let f = tree["filters"] as? [String: Any] {
            let list = { (k: String) in (f[k] as? [Any] ?? []).map { "\($0)" } }
            s.filters = Filters(blacklistCompanies: list("blacklist_companies"), titleMustContain: list("title_must_contain"),
                                titleExclude: list("title_exclude"))
        }
        if let l = tree["limits"] as? [String: Any] {
            s.limits.maxAppliesPerRun = l["max_applies_per_run"] as? Int ?? s.limits.maxAppliesPerRun
            s.limits.maxAttemptsPerJob = l["max_attempts_per_job"] as? Int ?? s.limits.maxAttemptsPerJob
            s.limits.otpTimeoutSec = l["otp_timeout_sec"] as? Int ?? s.limits.otpTimeoutSec
        }
        s.practiceMode = tree["dry_run"] as? Bool ?? true
        if let llm = tree["llm"] as? [String: Any], let model = llm["text_model"] as? String { s.ai.ollamaModel = model }
        if let sch = tree["schedule"] as? [String: Any] {
            s.schedule.hour = sch["hour"] as? Int ?? s.schedule.hour
            s.schedule.minute = sch["minute"] as? Int ?? s.schedule.minute
            s.schedule.weekdaysOnly = sch["weekdays_only"] as? Bool ?? true
        }
        return s
    }

    static func secretsFromEnv(_ text: String) -> Secrets {
        var values: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmed
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
            var v = String(t[t.index(after: eq)...]).trimmed
            if v.count >= 2, let q = v.first, (q == "'" || q == "\""), v.last == q {
                v = String(v.dropFirst().dropLast())
                if q == "\"" { v = v.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\") }
            }
            values[String(t[..<eq]).trimmed] = v
        }
        var s = Secrets()
        let user = values["IMAP_USER"] ?? ""
        let password = values["IMAP_APP_PASSWORD"] ?? ""
        if user.contains("@"), !user.contains("your_email"), !password.isEmpty, !password.contains("your_") {
            s.imapUser = user
            s.imapPassword = password
            s.imapHost = values["IMAP_HOST"] ?? EmailProviders.host(for: user) ?? ""
            s.imapPort = Int(values["IMAP_PORT"] ?? "") ?? 993
        }
        let portal = values["ATS_DEFAULT_PASSWORD"] ?? ""
        s.portalPassword = portal.isEmpty || portal == "StrongPortalPassword123!" ? Secrets.generatePortalPassword() : portal
        return s
    }
}
