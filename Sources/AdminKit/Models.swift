import Foundation

// What the cloud browser's AWS side looks like, read from the AWS CLI's JSON. Nothing here calls AWS: `CloudAdmin` does.

/// One started browser (a Chrome in the cloud, billed while it runs).
public struct BrowserSession: Identifiable, Equatable, Sendable {
    public var id: String
    public var status: String
    public var started: Date
    public var updated: Date?

    public init(id: String, status: String, started: Date, updated: Date? = nil) {
        self.id = id
        self.status = status
        self.started = started
        self.updated = updated
    }

    public var running: Bool { status == "READY" }
    /// How long it ran (so far, for one still running).
    public func duration(now: Date = Date()) -> TimeInterval {
        max(0, (running ? now : updated ?? started).timeIntervalSince(started))
    }

    /// `aws bedrock-agentcore list-browser-sessions`, newest first.
    public static func list(_ data: Data) -> [BrowserSession] {
        let items = (AWSJSON.object(data)["items"] as? [[String: Any]]) ?? []
        return items.compactMap { item in
            guard let id = item["sessionId"] as? String, let started = AWSJSON.date(item["createdAt"]) else { return nil }
            return BrowserSession(id: id, status: item["status"] as? String ?? "", started: started, updated: AWSJSON.date(item["lastUpdatedAt"]))
        }
        .sorted { $0.started > $1.started }
    }
}

/// Someone invited to the cloud browser.
public struct Person: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Invited, and hasn't signed in yet (the temporary password lasts 7 days).
        case invited
        case active
        /// Locked out: can't sign in, and their browser is closed to the sign-ins their app still holds.
        case revoked
    }

    /// The account's permanent ID: what their browser and cookie profile are tagged with.
    public var id: String
    public var email: String
    public var state: State
    /// "Google", "Apple": the other ways they've signed in.
    public var linked: [String] = []
    public var created: Date?
    /// Their own browser and cookie profile (missing for someone invited before each person had their own).
    public var browserId: String?
    public var profileId: String?
    /// May ask the cloud AI.
    public var cloudAI = false
    /// Their recent browser sessions, newest first.
    public var sessions: [BrowserSession] = []

    public init(id: String, email: String, state: State, linked: [String] = [], created: Date? = nil, browserId: String? = nil,
                profileId: String? = nil, cloudAI: Bool = false, sessions: [BrowserSession] = []) {
        self.id = id
        self.email = email
        self.state = state
        self.linked = linked
        self.created = created
        self.browserId = browserId
        self.profileId = profileId
        self.cloudAI = cloudAI
        self.sessions = sessions
    }

    public var running: [BrowserSession] { sessions.filter(\.running) }
    public var lastUsed: Date? { sessions.first?.started }
    public var hasOwnBrowser: Bool { !(browserId ?? "").isEmpty && !(profileId ?? "").isEmpty }

    /// Sessions and hours in the last `days` days.
    public func usage(days: Int = 7, now: Date = Date()) -> (sessions: Int, hours: Double) {
        let recent = sessions.filter { $0.started > now.addingTimeInterval(-Double(days) * 86400) }
        return (recent.count, recent.reduce(0) { $0 + $1.duration(now: now) } / 3600)
    }

    /// How they sign in, in the invite script's words.
    public var signsInWith: String {
        switch state {
        case .revoked: "Revoked"
        case .invited: linked.isEmpty ? "Invited, not signed in yet" : "Signs in with \(linked.joined(separator: ", ")) (no password yet)"
        case .active: "Signs in with " + (["password or passkey"] + linked).joined(separator: ", ")
        }
    }

    /// `aws cognito-idp list-users`; `allowedAI` are the account IDs in the cloud AI's group
    /// (`list-users-in-group`, read with `ids`).
    public static func list(_ data: Data, allowedAI: Set<String> = []) -> [Person] {
        let users = (AWSJSON.object(data)["Users"] as? [[String: Any]]) ?? []
        return users.compactMap { user in
            // A Google or Apple sign-in that was joined to an invitation isn't a person of its own.
            guard user["UserStatus"] as? String != "EXTERNAL_PROVIDER" else { return nil }
            let attributes = AWSJSON.attributes(user["Attributes"])
            guard let id = attributes["sub"], let email = attributes["email"] else { return nil }
            let enabled = user["Enabled"] as? Bool ?? true
            let state: State = !enabled ? .revoked : user["UserStatus"] as? String == "FORCE_CHANGE_PASSWORD" ? .invited : .active
            var linked: [String] = []
            if let identities = attributes["identities"], let list = try? JSONSerialization.jsonObject(with: Data(identities.utf8)) as? [[String: Any]] {
                linked = list.compactMap { $0["providerName"] as? String }.map { $0 == "SignInWithApple" ? "Apple" : $0 }.sorted()
            }
            return Person(id: id, email: email, state: state, linked: linked, created: AWSJSON.date(user["UserCreateDate"]),
                          browserId: attributes["custom:browser"], profileId: attributes["custom:profile"], cloudAI: allowedAI.contains(id))
        }
        .sorted { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
    }

    /// The account IDs in a `list-users` or `list-users-in-group` reply.
    public static func ids(_ data: Data) -> Set<String> {
        Set(((AWSJSON.object(data)["Users"] as? [[String: Any]]) ?? []).compactMap { AWSJSON.attributes($0["Attributes"])["sub"] })
    }
}

/// The CloudFormation stack everything but people's browsers lives in (infra/cloud-browser.yaml).
public struct CloudStack: Equatable, Sendable {
    public var name: String
    public var status: String
    public var updated: Date?
    public var outputs: [String: String]
    public var parameters: [String: String]

    public init(name: String, status: String, updated: Date? = nil, outputs: [String: String] = [:], parameters: [String: String] = [:]) {
        self.name = name
        self.status = status
        self.updated = updated
        self.outputs = outputs
        self.parameters = parameters
    }

    public var userPoolId: String? { outputs["UserPoolId"] }
    public var region: String? { outputs["Region"] }
    public var signInHost: String? { outputs["SignInHost"] }
    public var helperFunction: String? { outputs["HelperFunction"] }
    public var helperModel: String? { outputs["HelperModel"] }
    /// Each person has a browser of their own (a stack from before that shares one between everyone).
    public var perPerson: Bool { outputs["CloudAIGroup"] != nil && parameters["PlaceAttributes"] == "true" }
    public var providers: [String] {
        (parameters["GoogleSignIn"] == "true" ? ["Google"] : []) + (parameters["AppleSignIn"] == "true" ? ["Apple"] : [])
    }
    /// Settled: not in the middle of an update, and the last one didn't fail.
    public var healthy: Bool { ["CREATE_COMPLETE", "UPDATE_COMPLETE"].contains(status) }
    public var busy: Bool { status.hasSuffix("_IN_PROGRESS") }

    /// `aws cloudformation describe-stacks --stack-name …`.
    public static func read(_ data: Data) -> CloudStack? {
        guard let stack = (AWSJSON.object(data)["Stacks"] as? [[String: Any]])?.first, let name = stack["StackName"] as? String else { return nil }
        func pairs(_ list: Any?, _ key: String, _ value: String) -> [String: String] {
            Dictionary(((list as? [[String: Any]]) ?? []).compactMap { item in
                (item[key] as? String).flatMap { k in (item[value] as? String).map { (k, $0) } }
            }, uniquingKeysWith: { a, _ in a })
        }
        return CloudStack(name: name, status: stack["StackStatus"] as? String ?? "",
                          updated: AWSJSON.date(stack["LastUpdatedTime"]) ?? AWSJSON.date(stack["CreationTime"]),
                          outputs: pairs(stack["Outputs"], "OutputKey", "OutputValue"),
                          parameters: pairs(stack["Parameters"], "ParameterKey", "ParameterValue"))
    }
}

/// The browsers and cookie profiles in the account, and which of them no account uses any more.
public struct Places: Equatable, Sendable {
    public var browsers: [String: String] = [:]   // ID → name
    public var profiles: [String: String] = [:]

    public init(browsers: [String: String] = [:], profiles: [String: String] = [:]) {
        self.browsers = browsers
        self.profiles = profiles
    }

    /// `list-browsers --type CUSTOM` and `list-browser-profiles`.
    public static func read(browsers: Data, profiles: Data) -> Places {
        func named(_ data: Data, _ list: String, _ id: String) -> [String: String] {
            Dictionary(((AWSJSON.object(data)[list] as? [[String: Any]]) ?? []).compactMap { item in
                (item[id] as? String).map { ($0, item["name"] as? String ?? "") }
            }, uniquingKeysWith: { a, _ in a })
        }
        return Places(browsers: named(browsers, "browserSummaries", "browserId"), profiles: named(profiles, "profileSummaries", "profileId"))
    }

    /// A person's browser and profile are named aa_<their ID without dashes>.
    static func isAPersons(_ name: String) -> Bool {
        name.count == 35 && name.hasPrefix("aa_") && name.dropFirst(3).allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// The IDs of people's browsers and profiles that no account in `people` points to (what `--tidy` deletes).
    public func unused(by people: [Person]) -> [String] {
        let used = Set(people.flatMap { [$0.browserId, $0.profileId].compactMap { $0 } })
        return (browsers.merging(profiles) { a, _ in a }).filter { Self.isAPersons($0.value) && !used.contains($0.key) }.keys.sorted()
    }

    /// The browser the cloud tests use (`--test-browser`), if it was made.
    public var hasTestBrowser: Bool { browsers.values.contains("aa_tests") }
}

/// This month's bill so far, by service.
public struct Cost: Equatable, Sendable {
    public var services: [(name: String, amount: Double)]
    public var currency: String

    public init(services: [(name: String, amount: Double)], currency: String = "USD") {
        self.services = services
        self.currency = currency
    }

    public var total: Double { services.reduce(0) { $0 + $1.amount } }

    public static func == (a: Cost, b: Cost) -> Bool {
        a.currency == b.currency && a.services.map(\.name) == b.services.map(\.name) && a.services.map(\.amount) == b.services.map(\.amount)
    }

    /// `aws ce get-cost-and-usage … --group-by Type=DIMENSION,Key=SERVICE`: what cost a cent or more, biggest first.
    public static func read(_ data: Data) -> Cost {
        var services: [String: Double] = [:]
        var currency = "USD"
        for period in (AWSJSON.object(data)["ResultsByTime"] as? [[String: Any]]) ?? [] {
            for group in (period["Groups"] as? [[String: Any]]) ?? [] {
                guard let name = (group["Keys"] as? [String])?.first,
                      let cost = (group["Metrics"] as? [String: Any])?["UnblendedCost"] as? [String: Any],
                      let amount = (cost["Amount"] as? String).flatMap(Double.init) else { continue }
                services[name, default: 0] += amount
                currency = cost["Unit"] as? String ?? currency
            }
        }
        return Cost(services: services.filter { $0.value >= 0.005 }.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }, currency: currency)
    }
}

public enum AWSJSON {
    static func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// Cognito's [{"Name": …, "Value": …}].
    static func attributes(_ list: Any?) -> [String: String] {
        Dictionary(((list as? [[String: Any]]) ?? []).compactMap { item in
            (item["Name"] as? String).flatMap { name in (item["Value"] as? String).map { (name, $0) } }
        }, uniquingKeysWith: { a, _ in a })
    }

    /// The CLI's times: "2026-11-13T15:26:04.517585+00:00" (any number of decimals, or none), or seconds since 1970.
    public static func date(_ value: Any?) -> Date? {
        if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds) }
        guard var text = value as? String else { return nil }
        if let dot = text.firstIndex(of: "."), let end = text[dot...].firstIndex(where: { "+-Z".contains($0) }) {
            text.removeSubrange(dot..<end)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
