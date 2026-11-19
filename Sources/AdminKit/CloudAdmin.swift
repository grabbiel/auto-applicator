import Foundation

/// Which AWS account and which copy of the project the admin app works with.
public struct AdminSettings: Codable, Equatable, Sendable {
    /// The AWS CLI profile with administrator access (the invite script's AWS_PROFILE).
    public var profile = "admin"
    public var region = "us-east-1"
    public var stack = "auto-applicator-cloud"
    /// The project folder: scripts/deploy_cloud.sh does every change, infra/cloud-browser.yaml is what's deployed.
    public var repo = CloudAdmin.builtFrom.path

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = (try? c.decodeIfPresent(String.self, forKey: .profile)) ?? profile
        region = (try? c.decodeIfPresent(String.self, forKey: .region)) ?? region
        stack = (try? c.decodeIfPresent(String.self, forKey: .stack)) ?? stack
        repo = (try? c.decodeIfPresent(String.self, forKey: .repo)) ?? repo
    }

    public var script: URL { URL(fileURLWithPath: repo).appendingPathComponent("scripts/deploy_cloud.sh") }
    public var template: URL { URL(fileURLWithPath: repo).appendingPathComponent("infra/cloud-browser.yaml") }
}

public enum AdminError: LocalizedError, Equatable {
    case noCLI
    /// The administrator's AWS sign-in ran out (they last hours): `aws sso login` or `aws login` renews it.
    case signedOut
    case noProject(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .noCLI: "The AWS command line tool isn't installed (brew install awscli)."
        case .signedOut: "Your AWS sign-in has expired."
        case .noProject(let path): "There's no scripts/deploy_cloud.sh in \(path). Choose the project folder in Settings."
        case .failed(let message): message
        }
    }
}

/// Everything the window shows, read in one go.
public struct CloudSnapshot: Equatable, Sendable {
    public var account: String
    public var stack: CloudStack?
    public var people: [Person] = []
    public var places = Places()
    /// The project's template differs from the deployed one (nil when that couldn't be compared).
    public var templateChanged: Bool?
    /// Questions the cloud AI was asked in the last 7 days.
    public var questions: Int?
    /// Google or Apple sign-ins the invite gate turned away in the last 7 days (no invitation for that address).
    public var refusals: Int?
    public var read = Date()

    public init(account: String, stack: CloudStack? = nil, people: [Person] = [], places: Places = Places(), templateChanged: Bool? = nil,
                questions: Int? = nil, refusals: Int? = nil, read: Date = Date()) {
        self.account = account
        self.stack = stack
        self.people = people
        self.places = places
        self.templateChanged = templateChanged
        self.questions = questions
        self.refusals = refusals
        self.read = read
    }
}

/// Reads the cloud browser's AWS side with the AWS CLI, and changes it only through scripts/deploy_cloud.sh (so the
/// terminal and this app can't come to do the same thing two different ways).
public struct CloudAdmin: Sendable {
    public var settings: AdminSettings

    public init(settings: AdminSettings) { self.settings = settings }

    /// The project this copy was built from.
    public static let builtFrom = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    var environment: [String: String] {
        ["AWS_PROFILE": settings.profile, "AWS_REGION": settings.region, "AWS_DEFAULT_REGION": settings.region, "AWS_PAGER": "",
         "AA_STACK": settings.stack]
    }

    /// What the CLI says when the sign-in ran out, in its several wordings.
    public static func isSignedOut(_ errors: String) -> Bool {
        let text = errors.lowercased()
        return ["token has expired", "expiredtoken", "session has expired", "unable to locate credentials", "aws sso login",
                "error loading sso token", "sso session", "invalidclienttokenid", "credentials have expired", "aws login"]
            .contains { text.contains($0) }
    }

    /// One read-only AWS CLI call, as JSON.
    public func aws(_ arguments: [String]) async throws -> Data {
        guard let cli = Shell.find("aws") else { throw AdminError.noCLI }
        let result = try await Shell.run(cli, arguments + ["--output", "json"], environment: environment)
        guard result.ok else {
            if Self.isSignedOut(result.errors) { throw AdminError.signedOut }
            throw AdminError.failed(result.errors.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Data(result.output.utf8)
    }

    public func load() async throws -> CloudSnapshot {
        let caller = AWSJSON.object(try await aws(["sts", "get-caller-identity"]))
        var snapshot = CloudSnapshot(account: caller["Account"] as? String ?? "")
        do {
            snapshot.stack = CloudStack.read(try await aws(["cloudformation", "describe-stacks", "--stack-name", settings.stack]))
        } catch AdminError.failed(let message) where message.contains("does not exist") {
            return snapshot   // nothing deployed yet
        }
        guard let stack = snapshot.stack, let pool = stack.userPoolId else { return snapshot }

        async let users = aws(["cognito-idp", "list-users", "--user-pool-id", pool])
        async let allowed = stack.perPerson ? aws(["cognito-idp", "list-users-in-group", "--user-pool-id", pool, "--group-name", "cloud-ai"]) : Data()
        async let browsers = aws(["bedrock-agentcore-control", "list-browsers", "--type", "CUSTOM"])
        async let profiles = aws(["bedrock-agentcore-control", "list-browser-profiles"])
        async let changed = templateChanged()
        async let asked = questions(function: stack.helperFunction)
        async let refused = refusals()
        var people = Person.list(try await users, allowedAI: Person.ids(try await allowed))
        snapshot.places = Places.read(browsers: try await browsers, profiles: try await profiles)
        snapshot.templateChanged = await changed
        snapshot.questions = await asked
        snapshot.refusals = await refused

        // Each person's recent sessions (their browser may be gone: then they have none).
        let sessions = await withTaskGroup(of: (String, [BrowserSession]).self) { group in
            for person in people {
                guard let browser = person.browserId, !browser.isEmpty else { continue }
                group.addTask {
                    let data = try? await aws(["bedrock-agentcore", "list-browser-sessions", "--browser-identifier", browser, "--max-results", "100"])
                    return (person.id, data.map(BrowserSession.list) ?? [])
                }
            }
            var all: [String: [BrowserSession]] = [:]
            for await (id, list) in group { all[id] = list }
            return all
        }
        for i in people.indices { people[i].sessions = sessions[people[i].id] ?? [] }
        snapshot.people = people
        snapshot.read = Date()
        return snapshot
    }

    /// Whether infra/cloud-browser.yaml in the project differs from the deployed template.
    func templateChanged() async -> Bool? {
        guard let local = try? String(contentsOf: settings.template, encoding: .utf8),
              let data = try? await aws(["cloudformation", "get-template", "--stack-name", settings.stack, "--template-stage", "Original",
                                         "--query", "TemplateBody"]),
              let deployed = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String else { return nil }
        return Self.asCloudFormationShowsIt(deployed) != Self.asCloudFormationShowsIt(local)
    }

    /// A template as CloudFormation hands it back: every character outside ASCII (an arrow, a dash) comes back as "?".
    /// (What it deployed has them right; only reading the template back loses them.)
    static func asCloudFormationShowsIt(_ template: String) -> String {
        String(String.UnicodeScalarView(template.unicodeScalars.map { $0.isASCII ? $0 : "?" })).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func questions(function: String?) async -> Int? {
        guard let function else { return nil }
        let format = ISO8601DateFormatter()
        let now = Date()
        guard let data = try? await aws(["cloudwatch", "get-metric-statistics", "--namespace", "AWS/Lambda", "--metric-name", "Invocations",
                                         "--dimensions", "Name=FunctionName,Value=\(function)", "--statistics", "Sum", "--period", "604800",
                                         "--start-time", format.string(from: now.addingTimeInterval(-7 * 86400)), "--end-time", format.string(from: now)])
        else { return nil }
        let points = (AWSJSON.object(data)["Datapoints"] as? [[String: Any]]) ?? []
        return Int(points.reduce(0) { $0 + (($1["Sum"] as? Double) ?? 0) })
    }

    /// How often the invite gate wrote "refused: … sign-in without an invitation" to its log in the last 7 days.
    func refusals() async -> Int? {
        let since = Int(Date().addingTimeInterval(-7 * 86400).timeIntervalSince1970 * 1000)
        guard let data = try? await aws(["logs", "filter-log-events", "--log-group-name", "/aws/lambda/auto-applicator-invite-gate",
                                         "--filter-pattern", "\"refused:\"", "--start-time", String(since), "--query", "length(events)"]) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? Int
    }

    /// This month's bill so far, by service. (AWS charges a cent for each look.)
    public func cost(now: Date = Date()) async throws -> Cost {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = DateFormatter()
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let end = calendar.date(byAdding: .day, value: 1, to: now)!
        return Cost.read(try await aws(["ce", "get-cost-and-usage", "--time-period", "Start=\(day.string(from: start)),End=\(day.string(from: end))",
                                        "--granularity", "MONTHLY", "--metrics", "UnblendedCost", "--group-by", "Type=DIMENSION,Key=SERVICE"]))
    }

    /// Runs scripts/deploy_cloud.sh with `arguments`: every change to the cloud goes through it.
    public func script(_ arguments: [String], onLine: (@Sendable (String) -> Void)? = nil) async throws -> CommandResult {
        guard FileManager.default.fileExists(atPath: settings.script.path) else { throw AdminError.noProject(settings.repo) }
        return try await Shell.run(URL(fileURLWithPath: "/bin/bash"), [settings.script.path] + arguments, environment: environment,
                                   directory: URL(fileURLWithPath: settings.repo), onLine: onLine)
    }

    /// Renews the administrator's sign-in: the CLI opens the browser, where you approve it.
    public func signIn(onLine: (@Sendable (String) -> Void)? = nil) async throws -> CommandResult {
        guard let cli = Shell.find("aws") else { throw AdminError.noCLI }
        let sso = try await Shell.run(cli, ["configure", "get", "sso_session", "--profile", settings.profile], environment: environment)
        let old = try await Shell.run(cli, ["configure", "get", "sso_start_url", "--profile", settings.profile], environment: environment)
        let usesSSO = !(sso.output + old.output).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return try await Shell.run(cli, (usesSSO ? ["sso", "login"] : ["login"]) + ["--profile", settings.profile], environment: environment, onLine: onLine)
    }
}
