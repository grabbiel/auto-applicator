import AdminKit
import AppKit
import Foundation
import Observation

/// A line of the activity log: a command this app ran, or something it printed.
struct LogLine: Identifiable, Equatable {
    enum Kind { case command, output, problem }
    let id = UUID()
    var time = Date()
    var kind: Kind
    var text: String
}

/// Something that can't be taken back, waiting for a yes.
struct Confirmation: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var button: String
    var action: @MainActor () async -> Void
}

@MainActor
@Observable
final class AdminModel {
    enum Tab: String, CaseIterable { case people = "People", cloud = "Cloud", activity = "Activity" }

    var tab = Tab.people
    var settings: AdminSettings { didSet { if settings != oldValue { saveSettings() } } }
    var snapshot: CloudSnapshot?
    var loading = false
    /// Why the cloud can't be read right now (signed out of AWS, no AWS CLI, an AWS error).
    var problem: AdminError?
    /// What's being changed right now ("Inviting a@example.com…"): one change at a time.
    var busy: String?
    /// How the last change ended.
    var note: (text: String, ok: Bool)?
    var log: [LogLine] = []
    var inviteEmail = ""
    var confirm: Confirmation?
    var cost: Cost?
    var costLoading = false
    /// The version in the project folder, and the one the published update feed offers.
    var projectVersion: String?
    var publishedVersion: String?
    var expanded: Set<String> = []
    var showSettings = false

    /// AA_ADMIN_DEMO=1: made-up people and no AWS, to look at the window.
    let demo = ProcessInfo.processInfo.environment["AA_ADMIN_DEMO"] == "1"

    private var admin: CloudAdmin { CloudAdmin(settings: settings) }
    private static let settingsKey = "settings"

    init() {
        settings = UserDefaults.standard.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(AdminSettings.self, from: $0) } ?? AdminSettings()
        if demo { snapshot = Demo.snapshot; projectVersion = "1.4.0"; publishedVersion = "1.3.0"; log = Demo.log }
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
    }

    var people: [Person] { snapshot?.people ?? [] }
    var working: Bool { busy != nil }
    /// "a@example.com" well enough to send to Cognito, which checks it properly.
    var canInvite: Bool {
        let parts = inviteEmail.trimmingCharacters(in: .whitespaces).split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !parts[1].hasSuffix(".") && !inviteEmail.contains(" ")
    }

    // MARK: reading

    func refresh() async {
        guard !demo, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            snapshot = try await admin.load()
            problem = nil
        } catch let error as AdminError {
            problem = error
        } catch {
            problem = .failed(error.localizedDescription)
        }
        await readVersions()
    }

    private func readVersions() async {
        let file = URL(fileURLWithPath: settings.repo).appendingPathComponent("VERSION")
        projectVersion = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        // The public feed the app's updater reads; nothing about this Mac or account goes with the request.
        guard let url = URL(string: "https://github.com/grabbiel/auto-applicator/releases/latest/download/update.json"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let feed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        publishedVersion = feed["version"] as? String
    }

    func lookUpCost() async {
        guard !costLoading else { return }
        if demo { cost = Demo.cost; return }
        costLoading = true
        defer { costLoading = false }
        append(.command, "aws ce get-cost-and-usage (this month, by service)")
        do {
            cost = try await admin.cost()
        } catch {
            failed(error)
        }
    }

    // MARK: changing (always through scripts/deploy_cloud.sh)

    func invite() async {
        let email = inviteEmail.trimmingCharacters(in: .whitespaces).lowercased()
        guard canInvite else { return }
        if await run("Inviting \(email)…", ["--invite", email]) { inviteEmail = "" }
    }

    func sendAgain(_ person: Person) async { await run("Sending \(person.email) the invitation again…", ["--invite", person.email]) }
    func letBackIn(_ person: Person) async { await run("Letting \(person.email) back in…", ["--invite", person.email]) }
    func repair(_ person: Person) async { await run("Giving \(person.email) a browser of their own…", ["--invite", person.email]) }
    func stop(_ person: Person) async { await run("Ending \(person.email)'s browser sessions…", ["--stop", person.email]) }

    func setCloudAI(_ person: Person, on: Bool) async {
        await run(on ? "Letting \(person.email) ask the cloud AI…" : "Taking the cloud AI from \(person.email)…", ["--cloud-ai", person.email, on ? "on" : "off"])
    }

    func revoke(_ person: Person) {
        confirm = Confirmation(title: "Lock \(person.email) out?",
                               message: "They can't sign in, their cloud browser is closed to their app at once, and any session they have running ends. Their saved cookies are kept, and you can let them back in.",
                               button: "Revoke") { [weak self] in await self?.run("Revoking \(person.email)…", ["--revoke", person.email]) }
    }

    func remove(_ person: Person) {
        confirm = Confirmation(title: "Remove \(person.email)?",
                               message: "This deletes their account, their cloud browser and the cookies it saved (their LinkedIn and company-site sign-ins there). It can't be undone; inviting them again starts them from nothing.",
                               button: "Remove") { [weak self] in await self?.run("Removing \(person.email)…", ["--remove", person.email]) }
    }

    func updateCloud() {
        confirm = Confirmation(title: "Update the cloud?",
                               message: "This deploys infra/cloud-browser.yaml from the project folder to your AWS account (a few minutes) and writes Resources/CloudConfig.json. People stay signed in.",
                               button: "Update") { [weak self] in await self?.run("Updating the cloud…", []) }
    }

    func tidy() {
        let count = snapshot.map { $0.places.unused(by: $0.people).count } ?? 0
        confirm = Confirmation(title: "Delete \(count) unused browser\(count == 1 ? "" : "s") and cookie profile\(count == 1 ? "" : "s")?",
                               message: "They belonged to accounts that no longer exist, so nobody can use them. Any cookies saved in them are deleted.",
                               button: "Delete") { [weak self] in await self?.run("Deleting what no account uses…", ["--tidy"]) }
    }

    func makeTestBrowser() async { await run("Making a browser for the cloud tests…", ["--test-browser"]) }

    /// Renews the AWS sign-in: the CLI opens your browser, where you approve it.
    func signIn() async {
        guard busy == nil else { return }
        busy = "Waiting for you to approve the AWS sign-in in your browser…"
        defer { busy = nil }
        append(.command, "aws login (profile \(settings.profile))")
        do {
            let result = try await admin.signIn { [weak self] line in Task { @MainActor in self?.append(.output, line) } }
            if result.ok {
                note = ("Signed in to AWS.", true)
                await refresh()
            } else {
                note = (Self.lastLine(result.errors) ?? "The AWS sign-in didn't finish.", false)
            }
        } catch {
            failed(error)
        }
    }

    /// One change at a time; what the script prints goes to the log, and its last line becomes the note.
    @discardableResult
    private func run(_ title: String, _ arguments: [String]) async -> Bool {
        guard busy == nil else { return false }
        busy = title
        defer { busy = nil }
        append(.command, (["deploy_cloud.sh"] + arguments).joined(separator: " "))
        if demo {
            append(.output, "(demo: nothing was changed)")
            note = ("Demo: nothing was changed.", true)
            return true
        }
        do {
            let result = try await admin.script(arguments) { [weak self] line in Task { @MainActor in self?.append(.output, line) } }
            if result.ok {
                note = (Self.lastLine(result.output) ?? "Done.", true)
            } else if CloudAdmin.isSignedOut(result.errors + result.output) {
                problem = .signedOut
                note = ("Your AWS sign-in has expired.", false)
            } else {
                note = (Self.lastLine(result.errors) ?? Self.lastLine(result.output) ?? "That didn't work (see Activity).", false)
            }
            await refresh()
            return result.ok
        } catch {
            failed(error)
            return false
        }
    }

    private func failed(_ error: Error) {
        if let error = error as? AdminError, error == .signedOut { problem = .signedOut }
        note = (error.localizedDescription, false)
        append(.problem, error.localizedDescription)
    }

    private func append(_ kind: LogLine.Kind, _ text: String) {
        let text = text.trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { return }
        log.append(LogLine(kind: kind, text: text))
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
    }

    static func lastLine(_ text: String) -> String? {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
    }

    // MARK: places in the AWS console

    func openConsole(_ path: String) {
        guard let url = URL(string: "https://\(settings.region).console.aws.amazon.com/\(path)") else { return }
        NSWorkspace.shared.open(url)
    }

    var logText: String {
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"
        return log.map { "\(time.string(from: $0.time))  \($0.kind == .command ? "$ " : "")\($0.text)" }.joined(separator: "\n")
    }
}

/// Made-up people for AA_ADMIN_DEMO=1.
enum Demo {
    static var snapshot: CloudSnapshot {
        let now = Date()
        func session(_ id: String, _ hoursAgo: Double, _ minutes: Double, running: Bool = false) -> BrowserSession {
            let started = now.addingTimeInterval(-hoursAgo * 3600)
            return BrowserSession(id: id, status: running ? "READY" : "TERMINATED", started: started, updated: started.addingTimeInterval(minutes * 60))
        }
        let people = [
            Person(id: "11111111-aaaa-4bbb-8ccc-000000000001", email: "you@example.com", state: .active, linked: ["Google"],
                   created: now.addingTimeInterval(-6 * 86400), browserId: "auto_applicator_browser-Q0aaaaaaaa", profileId: "auto_applicator_profile-skaaaaaaaa",
                   cloudAI: true, sessions: [session("01A", 0.4, 0, running: true), session("01B", 26, 50), session("01C", 50, 64)]),
            Person(id: "22222222-aaaa-4bbb-8ccc-000000000002", email: "sam@example.com", state: .active,
                   created: now.addingTimeInterval(-2 * 86400), browserId: "aa_22222222aaaa4bbb8ccc000000000002-Xy12345678",
                   profileId: "aa_22222222aaaa4bbb8ccc000000000002-Zw12345678", sessions: [session("02A", 5, 42)]),
            Person(id: "33333333-aaaa-4bbb-8ccc-000000000003", email: "alex@example.org", state: .invited,
                   created: now.addingTimeInterval(-3600), browserId: "aa_33333333aaaa4bbb8ccc000000000003-Ab12345678",
                   profileId: "aa_33333333aaaa4bbb8ccc000000000003-Cd12345678"),
            Person(id: "44444444-aaaa-4bbb-8ccc-000000000004", email: "former@example.net", state: .revoked,
                   created: now.addingTimeInterval(-20 * 86400), browserId: "aa_44444444aaaa4bbb8ccc000000000004-Ef12345678",
                   profileId: "aa_44444444aaaa4bbb8ccc000000000004-Gh12345678", sessions: [session("04A", 300, 30)]),
        ]
        let stack = CloudStack(name: "auto-applicator-cloud", status: "UPDATE_COMPLETE", updated: now.addingTimeInterval(-3 * 3600),
                               outputs: ["Region": "us-east-1", "UserPoolId": "us-east-1_EXAMPLE", "ClientId": "exampleclientid",
                                         "SignInHost": "auto-applicator-000000000000.auth.us-east-1.amazoncognito.com", "IdentityPoolId": "us-east-1:example",
                                         "CloudAIGroup": "cloud-ai", "HelperFunction": "auto-applicator-form-helper", "HelperModel": "us.amazon.nova-2-lite-v1:0"],
                               parameters: ["GoogleSignIn": "true", "AppleSignIn": "false", "PlaceAttributes": "true"])
        var browsers = Dictionary(uniqueKeysWithValues: people.compactMap { p in p.browserId.map { ($0, String($0.prefix { $0 != "-" })) } })
        browsers["aa_99999999aaaa4bbb8ccc000000000009-Zz12345678"] = "aa_99999999aaaa4bbb8ccc000000000009"
        return CloudSnapshot(account: "000000000000", stack: stack, people: people,
                             places: Places(browsers: browsers, profiles: [:]), templateChanged: true, questions: 37, refusals: 2)
    }

    static let cost = Cost(services: [("Amazon Bedrock AgentCore", 4.82), ("Amazon Bedrock", 0.31), ("AWS Lambda", 0.02)])

    static let log = [
        LogLine(kind: .command, text: "deploy_cloud.sh --invite alex@example.org"),
        LogLine(kind: .output, text: "Invited alex@example.org: Cognito emailed a temporary password (valid 7 days); Continue with Google works for this address too."),
        LogLine(kind: .output, text: "They get a cloud browser of their own and nothing else in your account."),
    ]
}
