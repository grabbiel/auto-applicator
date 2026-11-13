import Foundation

public enum WorkplaceType: String, Codable, CaseIterable, Sendable {
    case remote = "Remote", hybrid = "Hybrid", onSite = "On-site"
    var linkedInCode: String { switch self { case .onSite: "1"; case .remote: "2"; case .hybrid: "3" } }
}

public enum ExperienceLevel: String, Codable, CaseIterable, Sendable {
    case internship = "Internship", entry = "Entry level", associate = "Associate", midSenior = "Mid-Senior level"
    case director = "Director", executive = "Executive"
    var linkedInCode: String { String(Self.allCases.firstIndex(of: self)! + 1) }
}

public enum DatePosted: String, Codable, CaseIterable, Sendable {
    case past24h = "past_24h", pastWeek = "past_week", pastMonth = "past_month", any
    public var label: String {
        switch self {
        case .past24h: "Last 24 hours"
        case .pastWeek: "Last week"
        case .pastMonth: "Last month"
        case .any: "Any time"
        }
    }
    var linkedInCode: String? {
        switch self {
        case .any: nil
        case .pastMonth: "r2592000"
        case .pastWeek: "r604800"
        case .past24h: "r86400"
        }
    }
}

/// The job search and how runs behave. Stored as settings.json.
public struct Settings: Codable, Equatable, Sendable {
    public var search = SearchSettings()
    public var filters = Filters()
    public var limits = Limits()
    /// Practice mode: fill applications but stop before the final Submit (default until the user switches it off).
    public var practiceMode = true
    public var schedule = Schedule()
    public var ai = AISettings()
    /// Set once the first-run setup has been completed.
    public var setupComplete = false
    public var tourComplete = false
    /// Runs use the cloud browser (Chrome in the owner's AWS account) instead of the built-in one.
    public var cloudBrowser = false

    public init() {}

    enum CodingKeys: String, CodingKey {
        case search, filters, limits, schedule, ai
        case practiceMode = "practice_mode", setupComplete = "setup_complete", tourComplete = "tour_complete"
        case cloudBrowser = "cloud_browser"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        search = (try? c.decodeIfPresent(SearchSettings.self, forKey: .search)) ?? SearchSettings()
        filters = (try? c.decodeIfPresent(Filters.self, forKey: .filters)) ?? Filters()
        limits = (try? c.decodeIfPresent(Limits.self, forKey: .limits)) ?? Limits()
        practiceMode = (try? c.decodeIfPresent(Bool.self, forKey: .practiceMode)) ?? true
        schedule = (try? c.decodeIfPresent(Schedule.self, forKey: .schedule)) ?? Schedule()
        ai = (try? c.decodeIfPresent(AISettings.self, forKey: .ai)) ?? AISettings()
        setupComplete = (try? c.decodeIfPresent(Bool.self, forKey: .setupComplete)) ?? false
        tourComplete = (try? c.decodeIfPresent(Bool.self, forKey: .tourComplete)) ?? false
        cloudBrowser = (try? c.decodeIfPresent(Bool.self, forKey: .cloudBrowser)) ?? false
    }
}

public struct SearchSettings: Codable, Equatable, Sendable {
    /// Job titles; each one is its own LinkedIn search.
    public var keywords: [String] = []
    public var location = "United States"
    public var workplace: [WorkplaceType] = [.remote]
    public var levels: [ExperienceLevel] = []
    public var datePosted: DatePosted = .pastWeek
    /// Also apply on company sites (Greenhouse, Lever, Ashby, Workday, others), not only LinkedIn Easy Apply.
    public var includeExternal = false
    public var maxPages = 3

    public init() {}
    enum CodingKeys: String, CodingKey {
        case keywords, location, workplace, levels
        case datePosted = "date_posted", includeExternal = "include_external", maxPages = "max_pages"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keywords = (try? c.decodeIfPresent([String].self, forKey: .keywords)) ?? []
        location = (try? c.decodeIfPresent(String.self, forKey: .location)) ?? "United States"
        workplace = (try? c.decodeIfPresent([WorkplaceType].self, forKey: .workplace)) ?? [.remote]
        levels = (try? c.decodeIfPresent([ExperienceLevel].self, forKey: .levels)) ?? []
        datePosted = (try? c.decodeIfPresent(DatePosted.self, forKey: .datePosted)) ?? .pastWeek
        includeExternal = (try? c.decodeIfPresent(Bool.self, forKey: .includeExternal)) ?? false
        maxPages = min(max((try? c.decodeIfPresent(Int.self, forKey: .maxPages)) ?? 3, 1), 40)
    }

    public var cleanKeywords: [String] {
        var seen = Set<String>()
        return keywords.map(\.trimmed).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

public struct Filters: Codable, Equatable, Sendable {
    public var blacklistCompanies: [String] = []
    public var titleMustContain: [String] = []
    public var titleExclude: [String] = []

    public init(blacklistCompanies: [String] = [], titleMustContain: [String] = [], titleExclude: [String] = []) {
        self.blacklistCompanies = blacklistCompanies
        self.titleMustContain = titleMustContain
        self.titleExclude = titleExclude
    }

    enum CodingKeys: String, CodingKey {
        case blacklistCompanies = "blacklist_companies", titleMustContain = "title_must_contain", titleExclude = "title_exclude"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blacklistCompanies = (try? c.decodeIfPresent([String].self, forKey: .blacklistCompanies)) ?? []
        titleMustContain = (try? c.decodeIfPresent([String].self, forKey: .titleMustContain)) ?? []
        titleExclude = (try? c.decodeIfPresent([String].self, forKey: .titleExclude)) ?? []
    }
}

public struct Limits: Codable, Equatable, Sendable {
    public var maxAppliesPerRun = 10
    public var minDelaySec = 2.0
    public var maxDelaySec = 5.0
    public var otpTimeoutSec = 90
    public var maxFormSteps = 12
    public var maxAttemptsPerJob = 2

    public init() {}
    enum CodingKeys: String, CodingKey {
        case maxAppliesPerRun = "max_applies_per_run", minDelaySec = "min_delay_sec", maxDelaySec = "max_delay_sec"
        case otpTimeoutSec = "otp_timeout_sec", maxFormSteps = "max_form_steps", maxAttemptsPerJob = "max_attempts_per_job"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxAppliesPerRun = max(1, (try? c.decodeIfPresent(Int.self, forKey: .maxAppliesPerRun)) ?? 10)
        minDelaySec = max(0, (try? c.decodeIfPresent(Double.self, forKey: .minDelaySec)) ?? 2)
        maxDelaySec = max(minDelaySec, (try? c.decodeIfPresent(Double.self, forKey: .maxDelaySec)) ?? 5)
        otpTimeoutSec = max(10, (try? c.decodeIfPresent(Int.self, forKey: .otpTimeoutSec)) ?? 90)
        maxFormSteps = max(1, (try? c.decodeIfPresent(Int.self, forKey: .maxFormSteps)) ?? 12)
        maxAttemptsPerJob = max(1, (try? c.decodeIfPresent(Int.self, forKey: .maxAttemptsPerJob)) ?? 2)
    }
}

public struct Schedule: Codable, Equatable, Sendable {
    public var enabled = false
    public var hour = 9
    public var minute = 30
    public var weekdaysOnly = true
    /// Proves a scheduled-run request came from this Mac's launchd job, not a web page.
    public var token = UUID().uuidString

    public init() {}
    enum CodingKeys: String, CodingKey { case enabled, hour, minute, token, weekdaysOnly = "weekdays_only" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        hour = min(max((try? c.decodeIfPresent(Int.self, forKey: .hour)) ?? 9, 0), 23)
        minute = min(max((try? c.decodeIfPresent(Int.self, forKey: .minute)) ?? 30, 0), 59)
        weekdaysOnly = (try? c.decodeIfPresent(Bool.self, forKey: .weekdaysOnly)) ?? true
        token = (try? c.decodeIfPresent(String.self, forKey: .token)) ?? UUID().uuidString
    }

    public var summary: String {
        let time = String(format: "%d:%02d", hour % 12 == 0 ? 12 : hour % 12, minute) + (hour < 12 ? " AM" : " PM")
        return (weekdaysOnly ? "Weekdays" : "Every day") + " at " + time
    }
}

public enum AIEngineChoice: String, Codable, CaseIterable, Sendable {
    /// Apple Intelligence when this Mac has it, otherwise the downloadable model.
    case automatic
    /// Apple's on-device model (macOS 26+, Apple Intelligence on): nothing to download.
    case apple
    /// A larger open model run by Ollama on this Mac (a one-time download of a few GB).
    case ollama
}

public struct AISettings: Codable, Equatable, Sendable {
    public var engine: AIEngineChoice = .automatic
    public var ollamaModel = "qwen2.5:7b"

    public init() {}
    enum CodingKeys: String, CodingKey { case engine, ollamaModel = "ollama_model" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = (try? c.decodeIfPresent(AIEngineChoice.self, forKey: .engine)) ?? .automatic
        ollamaModel = (try? c.decodeIfPresent(String.self, forKey: .ollamaModel)) ?? "qwen2.5:7b"
    }
}

/// Passwords, kept out of settings.json in a file only this user can read.
public struct Secrets: Codable, Equatable, Sendable {
    public var imapHost = ""
    public var imapPort = 993
    public var imapUser = ""
    public var imapPassword = ""
    /// Used when a company site (e.g. Workday) needs a candidate account. Generated once.
    public var portalPassword = ""
    /// The cloud browser sign-in (a refresh token that expires on its own) and who it belongs to.
    public var cloudRefreshToken = ""
    public var cloudEmail = ""

    public init() {}
    enum CodingKeys: String, CodingKey {
        case imapHost = "imap_host", imapPort = "imap_port", imapUser = "imap_user", imapPassword = "imap_password"
        case portalPassword = "portal_password", cloudRefreshToken = "cloud_refresh_token", cloudEmail = "cloud_email"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imapHost = (try? c.decodeIfPresent(String.self, forKey: .imapHost)) ?? ""
        imapPort = (try? c.decodeIfPresent(Int.self, forKey: .imapPort)) ?? 993
        imapUser = (try? c.decodeIfPresent(String.self, forKey: .imapUser)) ?? ""
        imapPassword = (try? c.decodeIfPresent(String.self, forKey: .imapPassword)) ?? ""
        portalPassword = (try? c.decodeIfPresent(String.self, forKey: .portalPassword)) ?? ""
        cloudRefreshToken = (try? c.decodeIfPresent(String.self, forKey: .cloudRefreshToken)) ?? ""
        cloudEmail = (try? c.decodeIfPresent(String.self, forKey: .cloudEmail)) ?? ""
    }

    public var emailConfigured: Bool { imapUser.contains("@") && !imapPassword.isEmpty && !imapHost.isEmpty }

    /// A strong password that satisfies typical portal rules (upper, lower, digit, symbol).
    public static func generatePortalPassword() -> String {
        let upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ"), lower = Array("abcdefghijkmnpqrstuvwxyz"), digits = Array("23456789")
        let symbols = Array("!@#$%&*?")
        var chars = [upper.randomElement()!, lower.randomElement()!, digits.randomElement()!, symbols.randomElement()!]
        let all = upper + lower + digits
        while chars.count < 16 { chars.append(all.randomElement()!) }
        return String(chars.shuffled())
    }
}
