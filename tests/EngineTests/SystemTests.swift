import Darwin
import XCTest
@testable import Engine

final class SystemTests: XCTestCase {
    func testSchedulePlist() {
        var s = Schedule()
        s.hour = 8
        s.minute = 5
        s.token = "abc"
        let plist = Scheduler.plist(s, logs: URL(fileURLWithPath: "/tmp/logs"))
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/usr/bin/open", "-g", "autoapplicator://scheduled-run?token=abc"])
        let cal = plist["StartCalendarInterval"] as? [[String: Int]]
        XCTAssertEqual(cal?.count, 5)
        XCTAssertEqual(cal?.first, ["Hour": 8, "Minute": 5, "Weekday": 1])
        s.weekdaysOnly = false
        XCTAssertEqual((Scheduler.plist(s, logs: URL(fileURLWithPath: "/tmp"))["StartCalendarInterval"] as? [[String: Int]]), [["Hour": 8, "Minute": 5]])
        XCTAssertEqual(s.summary, "Every day at 8:05 AM")
    }

    /// The supervisor ends its helper (and the helper's children) when the app it watches goes away.
    func testSupervisorStopsHelpersWhenTheAppDies() throws {
        let supervisor = productsDir.appendingPathComponent("AutoApplicator")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: supervisor.path), "build the app product first")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pidFile = dir.appendingPathComponent("pids")
        // a stand-in "app" (sleep) that the supervisor watches; the helper starts a grandchild and records both pids
        let fakeApp = Process()
        fakeApp.executableURL = URL(fileURLWithPath: "/bin/sleep")
        fakeApp.arguments = ["30"]
        try fakeApp.run()
        let sup = Process()
        sup.executableURL = supervisor
        sup.arguments = [Supervisor.flag, String(fakeApp.processIdentifier), "--", "/bin/sh", "-c",
                         "sleep 300 & echo $$ $! > '\(pidFile.path)'; wait"]
        try sup.run()
        var pids: [pid_t] = []
        for _ in 0..<50 where pids.count < 2 {
            usleep(100_000)
            pids = ((try? String(contentsOf: pidFile, encoding: .utf8)) ?? "").split(separator: " ").compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        XCTAssertEqual(pids.count, 2)
        XCTAssertTrue(pids.allSatisfy { kill($0, 0) == 0 })
        fakeApp.terminate()  // the app quits (or crashes)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, pids.contains(where: { kill($0, 0) == 0 }) || sup.isRunning { usleep(100_000) }
        XCTAssertFalse(sup.isRunning, "the supervisor exits")
        for pid in pids { XCTAssertNotEqual(kill(pid, 0), 0, "helper \(pid) is gone") }
    }

    /// When the app and its supervisor are killed together, the next launch stops the helper they left behind, and
    /// leaves alone a helper whose supervisor is still watching it.
    func testOrphanedHelpersAreStoppedOnNextLaunch() throws {
        let supervisor = productsDir.appendingPathComponent("AutoApplicator")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: supervisor.path), "build the app product first")
        let registry = FileManager.default.temporaryDirectory.appendingPathComponent("reg-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: registry); Supervisor.registry = nil }
        Supervisor.registry = registry
        let sup = Process()
        sup.executableURL = supervisor
        sup.arguments = [Supervisor.flag, String(getpid()), "--", "/bin/sh", "-c", "sleep 300 & wait"]
        sup.environment = ["AA_SUPERVISOR_REGISTRY": registry.path]
        try sup.run()
        var helper: pid_t = 0
        for _ in 0..<50 where helper == 0 {
            usleep(100_000)
            helper = ((try? FileManager.default.contentsOfDirectory(atPath: registry.path)) ?? []).compactMap { pid_t($0) }.first ?? 0
        }
        XCTAssertNotEqual(helper, 0, "the supervisor notes its helper")
        XCTAssertEqual(Supervisor.reapOrphans(), 0, "a supervised helper is left alone")
        XCTAssertEqual(kill(helper, 0), 0)

        kill(sup.processIdentifier, SIGKILL)  // force quit: nothing is left to stop the helper
        sup.waitUntilExit()
        var adopted = false
        for _ in 0..<50 where !adopted {
            usleep(100_000)
            adopted = Supervisor.processInfo(helper)?.pbi_ppid == 1
        }
        XCTAssertTrue(adopted, "the helper outlives its supervisor")
        XCTAssertEqual(Supervisor.reapOrphans(), 1)
        XCTAssertNotEqual(kill(-helper, 0), 0, "the helper's whole group is gone")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: registry.path), [])
    }

    var productsDir: URL {
        Bundle(for: SystemTests.self).bundleURL.deletingLastPathComponent()
    }

    func testMigrationFromVersion03() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mig-\(UUID().uuidString)", isDirectory: true)
        let paths = AppPaths(home: dir).ensure()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: Fixture.url("legacy/profile.example.yaml"), to: paths.legacyProfile)
        try FileManager.default.copyItem(at: Fixture.url("legacy/config.yaml"), to: paths.legacyConfig)
        try "IMAP_USER=jane@gmail.com\nIMAP_APP_PASSWORD='abcd efgh ijkl mnop'\nATS_DEFAULT_PASSWORD=StrongPortalPassword123!\n"
            .write(to: paths.legacyEnv, atomically: true, encoding: .utf8)
        let result = LegacyMigration.runIfNeeded(paths: paths)
        XCTAssertTrue(result.migrated)
        let store = Store(paths: paths)
        let profile = try XCTUnwrap(store.loadProfile())
        XCTAssertEqual(profile.personal.fullName, "Jane Doe")
        XCTAssertEqual(profile.experienceYears["Python"], 6)
        XCTAssertEqual(profile.workHistory.count, 2)
        XCTAssertEqual(profile.extraAnswers["Are you comfortable working in a fast-paced environment?"], "Yes")
        let settings = store.loadSettings()
        XCTAssertTrue(settings.setupComplete)
        XCTAssertFalse(settings.search.cleanKeywords.isEmpty)
        let secrets = store.loadSecrets()
        XCTAssertEqual(secrets.imapHost, "imap.gmail.com")
        XCTAssertEqual(secrets.imapPassword, "abcd efgh ijkl mnop")
        XCTAssertNotEqual(secrets.portalPassword, "StrongPortalPassword123!", "the placeholder password is replaced")
        XCTAssertEqual(secrets.portalPassword.count, 16)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.legacyProfile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("previous-version/profile.yaml").path))
        XCTAssertFalse(LegacyMigration.runIfNeeded(paths: paths).migrated, "runs once")
    }

    func testResumeFactsMerge() {
        var p = Profile()
        p.personal.firstName = "Typed"
        var facts = ResumeFacts()
        facts.firstName = "Parsed"
        facts.lastName = "Person"
        facts.email = "p@example.com"
        facts.skills = ["Swift", "SQL"]
        facts.experienceYears = ["Swift": 4]
        facts.totalYears = 7
        facts.merge(into: &p)
        XCTAssertEqual(p.personal.firstName, "Typed", "never overwrites what the user typed")
        XCTAssertEqual(p.personal.lastName, "Person")
        XCTAssertEqual(p.skills, ["Swift", "SQL"])
        XCTAssertEqual(p.experienceYears, ["Swift": 4, "total": 7])
    }

    func testResumeBasicsAndSections() {
        let text = """
        JANE DOE
        Austin, TX · jane.doe@example.com · (512) 555-0101 · linkedin.com/in/janedoe · github.com/jdoe
        SUMMARY
        Backend engineer.
        EXPERIENCE
        Acme Corp — Senior Engineer, 2022-03 – Present
        • Led things
        EDUCATION
        University of Texas, BS Computer Science, 2019
        SKILLS
        Python, SQL, AWS (4 years), Docker
        """
        let f = ResumeReader.basics(text)
        XCTAssertEqual(f.firstName, "Jane")
        XCTAssertEqual(f.lastName, "Doe")
        XCTAssertEqual(f.email, "jane.doe@example.com")
        XCTAssertEqual(f.phone, "(512) 555-0101")
        XCTAssertEqual(f.linkedin, "https://linkedin.com/in/janedoe")
        XCTAssertEqual(f.github, "https://github.com/jdoe")
        let parts = ResumeReader.sections(text)
        XCTAssertEqual(Set(parts.keys), ["header", "summary", "experience", "education", "skills"])
        XCTAssertEqual(ResumeReader.splitList(parts["skills"]!), ["Python", "SQL", "AWS (4 years)", "Docker"])
        XCTAssertEqual(ResumeReader.yearsSpanned([Role(company: "A", title: "B", startDate: "2020-01", endDate: "2022-01")]), 2)
    }

    func testYAMLMatchesPyYAML() throws {
        let text = """
        a: 1
        b: yes
        c: "quoted: value"
        d:
          - x
          - y: 2
            z: [1, 2]
        e: >-
          folded
          text
        f: null
        g: '2026-01-01'
        """
        let tree = try XCTUnwrap(YAML.parse(text) as? [String: Any])
        XCTAssertEqual(tree["a"] as? Int, 1)
        XCTAssertEqual(tree["b"] as? Bool, true)
        XCTAssertEqual(tree["c"] as? String, "quoted: value")
        let d = try XCTUnwrap(tree["d"] as? [Any])
        XCTAssertEqual(d.first as? String, "x")
        XCTAssertEqual((d.last as? [String: Any])?["z"] as? [Int], [1, 2])
        XCTAssertEqual(tree["e"] as? String, "folded text")
        XCTAssertTrue(tree["f"] is NSNull)
        XCTAssertEqual(tree["g"] as? String, "2026-01-01")
    }
}

/// Request signing against AWS's published Signature Version 4 examples.
final class SigV4Tests: XCTestCase {
    let creds = AWSCredentials(accessKeyId: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", sessionToken: nil,
                               expiration: .distantFuture)
    let date = Date(timeIntervalSince1970: 1_440_938_160)  // 2015-08-30 12:36:00 UTC

    func sign(_ url: String) -> String? {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "GET"
        SigV4(credentials: creds, region: "us-east-1", service: "service").sign(&req, date: date)
        return req.value(forHTTPHeaderField: "Authorization")
    }

    func testVanilla() {
        XCTAssertEqual(sign("https://example.amazonaws.com/"),
                       "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }

    func testQueryOrder() {
        XCTAssertEqual(sign("https://example.amazonaws.com/?Param2=value2&Param1=value1"),
                       "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500")
    }

    func testIDTokenClaimsAndForm() {
        let payload = Data(#"{"email":"jane@example.com","exp":1900000000}"#.utf8).base64URL
        XCTAssertEqual(CloudAccount.claims("h.\(payload).s")["email"] as? String, "jane@example.com")
        XCTAssertEqual(String(decoding: CloudAccount.form(["b": "x y", "a": "1/2"]), as: UTF8.self), "a=1%2F2&b=x%20y")
    }

    func testSignInErrors() {
        // The invite gate's refusal, as Cognito passes it back to the app.
        XCTAssertEqual(CloudError.signIn("invalid_request", description: "PreSignUp+failed+with+error+This+address+has+no+invitation.."),
                       .failed("This address has no invitation."))
        XCTAssertEqual(CloudError.signIn("invalid_request", description: "Already found an entry for username Google_1234567890"),
                       .joined(provider: "Google"))
        XCTAssertEqual(CloudError.signIn("invalid_request", description: "Already+found+an+entry+for+username+SignInWithApple_001.abc"),
                       .joined(provider: "SignInWithApple"))
        XCTAssertEqual(CloudError.signIn("access_denied", description: nil), .failed("access_denied"))
    }

    func testSignInRequestAndProviders() throws {
        let old = #"{"region":"us-east-1","userPoolId":"p","clientId":"c","signInHost":"h.example.com","identityPoolId":"i","browserId":"b","browserProfileId":"f"}"#
        let config = try JSONDecoder().decode(CloudConfig.self, from: Data(old.utf8))  // a file from before Google and Apple
        XCTAssertEqual(config.providerNames, [])
        var both = config
        both.signInProviders = ["Google", "SignInWithApple"]
        XCTAssertEqual(both.providerNames, ["Google", "Apple"])

        let account = CloudAccount(config: config, refreshToken: nil) { _ in }
        func items(_ url: URL) -> [String: String] {
            Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        }
        XCTAssertNil(items(account.signInRequest().url)["identity_provider"])
        let google = items(account.signInRequest(identityProvider: "Google").url)
        XCTAssertEqual(google["identity_provider"], "Google")
        XCTAssertEqual(google["code_challenge_method"], "S256")
    }
}

/// The cloud browser keeps cookies between sessions through its profile (needs AA_CLOUD_TEST=1 and AWS credentials).
@MainActor
final class CloudSessionTests: XCTestCase {
    func testProfileKeepsCookiesBetweenSessions() async throws {
        let probe = try await makeCloudTestAgent()  // checks the environment; no profile
        await probe.cloud?.stop(saveProfile: false)
        let env = ProcessInfo.processInfo.environment
        let creds = AWSCredentials(accessKeyId: env["AWS_ACCESS_KEY_ID"]!, secretAccessKey: env["AWS_SECRET_ACCESS_KEY"]!,
                                   sessionToken: env["AWS_SESSION_TOKEN"], expiration: .distantFuture)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let config = try JSONDecoder().decode(CloudConfig.self, from: Data(contentsOf: repo.appendingPathComponent("Resources/CloudConfig.json")))
        let value = UUID().uuidString
        let cookie = HTTPCookie(properties: [.name: "aa_probe", .value: value, .domain: ".example.com", .path: "/", .secure: "TRUE",
                                             .expires: Date().addingTimeInterval(600)])!

        let first = try await CloudBrowser.start(config: config, credentials: { creds }, timeout: 900)
        await first.setCookies([cookie])
        let set = await first.cookies(for: "example.com")
        XCTAssertEqual(set.first { $0.name == "aa_probe" }?.value, value)
        await first.stop()  // saves the profile

        let second = try await CloudBrowser.start(config: config, credentials: { creds }, timeout: 900)
        let kept = await second.cookies(for: "example.com")
        XCTAssertEqual(kept.first { $0.name == "aa_probe" }?.value, value, "the profile brought the cookie back")
        _ = try? await second.call("Storage.deleteCookies", ["name": "aa_probe", "domain": ".example.com"], onPage: false)
        try? await second.call("Network.deleteCookies", ["name": "aa_probe", "domain": ".example.com"])
        await second.stop()
    }
}
