import AppKit
import XCTest
@testable import Engine

enum Fixture {
    static var dir: URL { Bundle.module.url(forResource: "Fixtures", withExtension: nil)! }
    static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }
    static func data(_ name: String) -> Data { try! Data(contentsOf: url(name)) }

    /// The example profile from version 0.3 (also exercises the YAML reader).
    static var profile: Profile {
        let text = try! String(contentsOf: url("legacy/profile.example.yaml"), encoding: .utf8)
        let json = try! JSONSerialization.data(withJSONObject: try! YAML.parse(text))
        return try! JSONDecoder().decode(Profile.self, from: json)
    }

    static let job = JobContext(title: "Backend Engineer", company: "Initech", location: "Remote", description: "Python, AWS")
}

/// A throwaway support folder with a profile, settings and a résumé.
final class TestHome {
    let paths: AppPaths
    let db: Database

    init(profile: Profile = Fixture.profile) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aa-test-\(UUID().uuidString)", isDirectory: true)
        paths = AppPaths(home: dir).ensure()
        let store = Store(paths: paths)
        try store.save(profile)
        var settings = Settings()
        settings.limits.minDelaySec = 0
        settings.limits.maxDelaySec = 0
        settings.limits.otpTimeoutSec = 10
        try store.save(settings)
        try Data("%PDF-1.4\n%fake resume\n".utf8).write(to: paths.resumeFile)
        db = try Database(paths: paths)
    }

    deinit { try? FileManager.default.removeItem(at: paths.home) }
}

/// Stands in for the AI model: answers each field from a label → (answer, confidence) table, the way the real
/// model receives them (it reads the same prompt the app builds).
final class FakeModel: LanguageModel, @unchecked Sendable {
    var table: [String: (String, Confidence)]
    var feedbackTable: [String: (String, Confidence)]
    var defaultAnswer: (String, Confidence)
    var evidence = "Backend engineer building Python services"
    var compact = false
    private(set) var calls: [[String]] = []          // labels per form call
    private(set) var feedback: [[String]] = []       // labels that came with a form error
    private(set) var coverLetters = 0

    init(_ table: [String: (String, Confidence)] = [:], feedback: [String: (String, Confidence)] = [:], default d: (String, Confidence) = ("", .low)) {
        self.table = table
        feedbackTable = feedback
        defaultAnswer = d
    }

    var displayName: String { "Fake" }
    var promptBudget: Int { compact ? 7000 : 30000 }

    func generate(instructions: String, prompt: String, schema: AISchema) async throws -> [String: Any] {
        let keys = schema.orderedKeys
        if keys.contains("submitted") {
            return ["evidence": "fake", "submitted": prompt.lowercased().contains("thank")]
        }
        if keys.contains("code") { return ["code": "", "verification_url": ""] }
        // form fields: lines like `field1: "Label" (type, required)` and an optional rejection note below
        var out: [String: Any] = [:]
        var labels: [String] = []
        var rejected: [String] = []
        let lines = prompt.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            guard let g = Regex(#"^(field\d+): "(.*)" \("#, []).firstGroups(line), let key = g[1], let label = g[2] else { continue }
            labels.append(label)
            let hasFeedback = i + 1 < lines.count && lines[i + 1].contains("The form rejected")
            if hasFeedback { rejected.append(label) }
            var (answer, conf) = defaultAnswer
            for (k, v) in (hasFeedback ? feedbackTable : table) where label.lowercased().contains(k.lowercased()) {
                (answer, conf) = v
                break
            }
            out[key] = ["evidence": evidence, "answer": answer, "confidence": conf.rawValue]
        }
        calls.append(labels)
        feedback.append(rejected)
        return out
    }

    func generateText(instructions: String, prompt: String) async throws -> String {
        coverLetters += 1
        return "Dear Initech team, I am excited to apply.\n\nJane Doe"
    }
}

/// An inbox held in memory.
final class FakeMailbox: MailSession, @unchecked Sendable {
    var messages: [(uid: Int, raw: Data, seen: Bool)]
    var onRefresh: (() -> Void)?

    init(_ raws: [Data]) { messages = raws.enumerated().map { ($0.offset + 1, $0.element, false) } }

    func refresh() async throws { onRefresh?() }
    func uids(since date: Date) async throws -> [Int] { messages.map(\.uid).reversed() }
    func fetch(uid: Int) async throws -> Data? { messages.first { $0.uid == uid }?.raw }
    func markSeen(uid: Int) async throws { if let i = messages.firstIndex(where: { $0.uid == uid }) { messages[i].seen = true } }
    func unseenCount() async throws -> Int { messages.filter { !$0.seen }.count }
    func close() {}
}

func field(_ label: String, _ type: FieldSpec.FieldType = .text, _ options: [String] = [], required: Bool = true, id: String = "field_1",
           current: String = "", maxLength: Int? = nil) -> FieldSpec {
    FieldSpec(id: id, label: label, type: type, options: options, required: required, currentValue: current, maxLength: maxLength)
}

/// Rewrites a fixture email's Date header (fixtures are dated 2026-11-13 15:00 UTC).
func email(_ name: String, date: Date = Date()) -> Data {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
    var text = String(decoding: Fixture.data("emails/\(name).eml"), as: UTF8.self)
    text = text.replacingOccurrences(of: #"(?m)^Date: .*$"#, with: "Date: \(f.string(from: date))", options: .regularExpression)
    return Data(text.utf8)
}

/// Pages a test opens, in whichever browser it uses. The built-in browser reads them from disk; the cloud browser
/// asks this Mac for them (`https://fixtures.test/<name>`, and HTML a test sets for a given address).
@MainActor
enum TestPages {
    static var html: [String: String] = [:]
}

@MainActor
extension WebAgent {
    func openFixture(_ name: String, query: String = "") async throws {
        if cloud != nil {
            try await load(URL(string: "https://fixtures.test/\(name)\(query)")!)
        } else {
            webView.loadFileURL(URL(string: Fixture.url(name).absoluteString + query)!, allowingReadAccessTo: Fixture.dir)
            try await waitForLoad()
        }
    }

    func loadTestHTML(_ html: String, base: URL) async throws {
        if cloud != nil {
            TestPages.html[base.absoluteString] = html
            try await load(base)
        } else {
            webView.loadHTMLString(html, baseURL: base)
            try await waitForLoad()
        }
    }
}

/// A cloud browser session for tests: AA_CLOUD_TEST=1 plus AWS credentials in the environment (e.g. from
/// `aws configure export-credentials --profile admin --format env`) and Resources/CloudConfig.json. It never uses or
/// saves the app's cookie profile.
@MainActor
func makeCloudTestAgent() async throws -> WebAgent {
    let env = ProcessInfo.processInfo.environment
    guard env["AA_CLOUD_TEST"] == "1", let key = env["AWS_ACCESS_KEY_ID"], let secret = env["AWS_SECRET_ACCESS_KEY"] else {
        throw XCTSkip("Set AA_CLOUD_TEST=1 and AWS credentials to test the cloud browser.")
    }
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard let data = try? Data(contentsOf: repo.appendingPathComponent("Resources/CloudConfig.json")),
          let config = try? JSONDecoder().decode(CloudConfig.self, from: data) else {
        throw XCTSkip("No Resources/CloudConfig.json (run scripts/deploy_cloud.sh).")
    }
    let creds = AWSCredentials(accessKeyId: key, secretAccessKey: secret, sessionToken: env["AWS_SESSION_TOKEN"], expiration: .distantFuture)
    let cloud = try await CloudBrowser.start(config: config, credentials: { creds }, timeout: 900, useProfile: false)
    try await cloud.serve { url in
        if url.host == "fixtures.test" {
            return (try? Data(contentsOf: Fixture.url(url.lastPathComponent))).map { ($0, "text/html; charset=utf-8") }
        }
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.query = nil
        guard let page = c?.url?.absoluteString, let html = TestPages.html[page] else { return nil }
        return (Data(html.utf8), "text/html; charset=utf-8")
    }
    return WebAgent(cloud: cloud)
}
