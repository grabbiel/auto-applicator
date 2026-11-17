import XCTest
@testable import Engine

/// The cloud AI: asked only about what the on-device AI couldn't answer, under the same rules, and what it answers
/// reaches the on-device AI.
final class CloudAITests: XCTestCase {
    let pairing = field("Are you comfortable pair programming for most of the day?", .radio, ["Yes", "No"], id: "f_pair")

    func testAnswersWhatTheOnDeviceAICouldntAndTeachesIt() async throws {
        let home = try TestHome()
        let local = FakeModel(["pair program": ("Yes", .low), "favorite color": ("Blue", .medium)])
        let cloud = FakeModel(["pair program": ("Yes", .high)])
        let answerer = Answerer(profile: Fixture.profile, db: home.db, ai: AIService(model: local), helper: AIService(model: cloud))
        let rust = field("Years of experience with Rust", .number, id: "f_rust")
        let color = field("Favorite color", .select, ["Red", "Blue"], id: "f_color")

        let res = await answerer.resolve([pairing, rust, color], job: Fixture.job)
        XCTAssertEqual(res.answers, ["f_pair": "Yes", "f_color": "Blue"])
        XCTAssertEqual(res.sources, ["f_pair": "cloud:high", "f_color": "llm:medium"])
        XCTAssertEqual(res.unresolved.map(\.id), ["f_rust"], "a question never guessed isn't sent to the cloud either")
        XCTAssertEqual(cloud.calls, [[pairing.label]], "only what the on-device AI missed")
        XCTAssertEqual(home.db.cacheSource(Answerer.hash(pairing)), "cloud:high")
        let email = Fixture.profile.personal.email, phone = Fixture.profile.personal.phone
        XCTAssertTrue(local.prompts[0].contains(email))
        XCTAssertFalse(cloud.prompts[0].contains(email), "the cloud gets no email address")
        XCTAssertFalse(cloud.prompts[0].contains(phone), "the cloud gets no phone number")
        XCTAssertTrue(cloud.prompts[0].contains("work_authorization:"), "but the rest of the profile")

        // The same question on the next form: from the cache, with no AI at all.
        let again = await answerer.resolve([pairing], job: Fixture.job)
        XCTAssertEqual(again.sources, ["f_pair": "cache"])

        // A related question: the on-device AI is shown the cloud's answer and may cite it.
        let related = field("Can you pair program with a teammate most days?", .radio, ["Yes", "No"], id: "f_related")
        local.table["pair program"] = ("Yes", .high)
        local.evidence = "comfortable pair programming for most of the day? A: Yes"
        let taught = await answerer.resolve([related], job: Fixture.job)
        XCTAssertTrue(local.prompts.last!.contains("Q: \(pairing.label) A: Yes"), local.prompts.last!)
        XCTAssertEqual(taught.sources, ["f_related": "llm:high"])
        XCTAssertEqual(cloud.calls.count, 1, "the cloud AI wasn't needed again")
    }

    func testTheCloudAIFollowsTheSameRules() async throws {
        let home = try TestHome()
        let cloud = FakeModel(["pair program": ("Yes", .high), "travel": ("Yes", .medium)])
        cloud.evidence = "Enjoys working from a beach in Bali"  // in neither the profile nor the job
        let answerer = Answerer(profile: Fixture.profile, db: home.db, ai: AIService(model: FakeModel()), helper: AIService(model: cloud))
        let res = await answerer.resolve([pairing], job: Fixture.job)
        XCTAssertEqual(res.unresolved.map(\.id), ["f_pair"], "an answer that cites nothing real is the person's to give")
        XCTAssertNil(home.db.cacheSource(Answerer.hash(pairing)))
    }

    func testAListTooLongForTheOnDeviceAIGoesToTheCloudAI() async throws {
        let home = try TestHome()
        let local = FakeModel(default: ("Yes", .high))
        local.compact = true
        let cloud = FakeModel(["product area": ("Backend Services", .high)])
        let answerer = Answerer(profile: Fixture.profile, db: home.db, ai: AIService(model: local), helper: AIService(model: cloud))
        // Like Fiserv's "Field of study": hundreds of options, more than the on-device AI's window holds.
        let options = (1...400).map { "Product area number \($0)" } + ["Backend Services"]
        let area = field("Which product area interests you most?", .select, options, id: "f_area")
        let res = await answerer.resolve([area], job: Fixture.job)
        XCTAssertEqual(res.answers["f_area"], "Backend Services")
        XCTAssertTrue(local.calls.isEmpty, "the on-device AI isn't shown a list it can't hold")
        XCTAssertEqual(cloud.calls, [[area.label]])
    }

    func testWorksWithoutTheOnDeviceAIUpToItsLimit() async throws {
        let home = try TestHome()
        let cloud = FakeModel(default: ("Yes", .high))
        let answerer = Answerer(profile: Fixture.profile, db: home.db, ai: nil, helper: AIService(model: cloud), helperBudget: 1)
        let travel = field("Are you open to occasional travel to client offices?", .radio, ["Yes", "No"], id: "f_travel")
        let res = await answerer.resolve([pairing, travel], job: Fixture.job)
        XCTAssertEqual(res.answers, ["f_pair": "Yes"])
        XCTAssertEqual(res.unresolved.map(\.id), ["f_travel"], "past the run's limit, the person answers")
        XCTAssertEqual(cloud.calls, [[pairing.label]])
    }

    func testStopsAskingWhenTheCloudAIIsUnavailable() async throws {
        let home = try TestHome()
        let cloud = FakeModel(default: ("Yes", .high))
        cloud.failure = AIError.unavailable("The model isn't enabled.")
        let answerer = Answerer(profile: Fixture.profile, db: home.db, ai: AIService(model: FakeModel()), helper: AIService(model: cloud))
        let first = await answerer.resolve([pairing], job: Fixture.job)
        XCTAssertEqual(first.unresolved.map(\.id), ["f_pair"])
        let travel = field("Are you open to occasional travel to client offices?", .radio, ["Yes", "No"], id: "f_travel")
        let second = await answerer.resolve([travel], job: Fixture.job)
        XCTAssertEqual(second.unresolved.map(\.id), ["f_travel"])
        XCTAssertEqual(cloud.prompts.count, 1, "asked once, then left alone for the rest of the run")
    }

    // MARK: the function

    func testCallsTheFunctionSignedAndReadsItsReplies() async throws {
        var config = Self.config
        let session = Stub.session { request, body in
            XCTAssertEqual(request.url?.absoluteString, "https://lambda.us-east-1.amazonaws.com/2015-03-31/functions/auto-applicator-form-helper/invocations")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("/us-east-1/lambda/aws4_request") == true)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Amz-Security-Token"), "token")
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["system"] as? String, "rules")
            XCTAssertEqual(json["prompt"] as? String, "fields")
            XCTAssertEqual((json["schema"] as? [String: Any])?["type"] as? String, "object")
            return (200, #"{"answer": {"field1": {"evidence": "e", "answer": "Yes", "confidence": "high"}}, "model": "m"}"#, [:])
        }
        let model = try XCTUnwrap(CloudModel(config: config, session: session) {
            AWSCredentials(accessKeyId: "AKIDEXAMPLE", secretAccessKey: "secret", sessionToken: "token", expiration: .distantFuture)
        })
        XCTAssertEqual(model.displayName, "Amazon Nova 2 Lite")
        let out = try await model.generate(instructions: "rules", prompt: "fields", schema: .object([("field1", .object([("answer", .string)]))]))
        XCTAssertEqual((out["field1"] as? [String: Any])?["answer"] as? String, "Yes")

        config.helperFunction = nil
        XCTAssertNil(CloudModel(config: config) { throw CloudError.signedOut }, "an app built before the cloud AI existed has none")
    }

    func testTurnsTheFunctionsRefusalsIntoErrors() {
        func read(_ status: Int, _ body: String, _ headers: [String: String] = [:]) -> Error? {
            let response = HTTPURLResponse(url: URL(string: "https://lambda.us-east-1.amazonaws.com/")!, statusCode: status, httpVersion: nil, headerFields: headers)
            do { _ = try CloudModel.read(Data(body.utf8), response); return nil } catch { return error }
        }
        func unavailable(_ e: Error?) -> Bool { if case AIError.unavailable? = e as? AIError { return true } else { return false } }
        func server(_ e: Error?) -> Bool { if case AIError.server? = e as? AIError { return true } else { return false } }
        if case AIError.contextTooLong? = read(200, #"{"error": "too long"}"#) as? AIError {} else { XCTFail("too long → shorter prompt") }
        XCTAssertTrue(unavailable(read(200, #"{"error": "ResourceNotFoundException"}"#)), "model not enabled: stop asking")
        XCTAssertTrue(unavailable(read(200, #"{"error": "AccessDeniedException"}"#)))
        XCTAssertTrue(unavailable(read(403, #"{"Message": "not authorized to perform lambda:InvokeFunction"}"#)), "no permission: stop asking")
        XCTAssertTrue(unavailable(read(404, #"{"Message": "Function not found"}"#)))
        XCTAssertTrue(server(read(200, #"{"error": "busy"}"#)), "busy: try the next question")
        XCTAssertTrue(server(read(429, #"{"Message": "Rate exceeded"}"#)))
        XCTAssertTrue(server(read(200, #"{"errorMessage": "Task timed out"}"#, ["X-Amz-Function-Error": "Unhandled"])))
        if case AIError.badOutput? = read(200, #"{"model": "m"}"#) as? AIError {} else { XCTFail("no answer") }
    }

    func testNamesTheModel() {
        XCTAssertEqual(CloudConfig.modelName("us.amazon.nova-2-lite-v1:0"), "Amazon Nova 2 Lite")
        XCTAssertEqual(CloudConfig.modelName("us.anthropic.claude-sonnet-4-6"), "Claude Sonnet 4.6")
        XCTAssertEqual(CloudConfig.modelName("us.anthropic.claude-haiku-4-5-20251001-v1:0"), "Claude Haiku 4.5")
        XCTAssertEqual(CloudConfig.modelName("us.openai.gpt-5.5"), "GPT 5.5")
        let old = try? JSONDecoder().decode(CloudConfig.self, from: Data(#"{"region":"us-east-1","userPoolId":"p","clientId":"c","signInHost":"h","identityPoolId":"i","browserId":"b","browserProfileId":"f"}"#.utf8))
        XCTAssertNotNil(old, "a file written before the cloud AI still loads")
        XCTAssertNil(old?.helperFunction)
    }

    /// A `cloud.json` left in the data folder from before the cloud AI existed (the real app ran a whole day without
    /// it): what the file leaves out comes from the app's own copy, but never from another deployment's.
    func testAnOldCloudFileStillGetsTheCloudAI() throws {
        var old = Self.config
        old.helperFunction = nil
        old.helperModel = nil
        let merged = try XCTUnwrap(CloudConfig.merged(old, builtIn: Self.config))
        XCTAssertEqual(merged.helperFunction, "auto-applicator-form-helper")
        XCTAssertEqual(merged.helperName, "Amazon Nova 2 Lite")
        XCTAssertEqual(merged.browserId, "b")

        var mine = old
        mine.helperFunction = "my-own-helper"
        XCTAssertEqual(CloudConfig.merged(mine, builtIn: Self.config)?.helperFunction, "my-own-helper", "the data folder's file wins")

        var elsewhere = Self.config
        elsewhere.userPoolId = "another-pool"
        XCTAssertNil(CloudConfig.merged(old, builtIn: elsewhere)?.helperFunction, "another sign-in's function can't be called")
        XCTAssertEqual(CloudConfig.merged(nil, builtIn: Self.config), Self.config)

        let home = try TestHome()
        try JSONEncoder().encode(old).write(to: home.paths.home.appendingPathComponent("cloud.json"))
        let bundleDir = home.paths.home.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(Self.config).write(to: bundleDir.appendingPathComponent("CloudConfig.json"))
        let bundle = try XCTUnwrap(Bundle(url: bundleDir))
        XCTAssertEqual(CloudConfig.load(paths: home.paths, bundle: bundle)?.helperFunction, "auto-applicator-form-helper")
    }

    /// Opt-in: the deployed function, with made-up details (AA_CLOUD_TEST=1 and AWS credentials allowed to invoke it).
    func testLiveCloudAI() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["AA_CLOUD_TEST"] == "1", let key = env["AWS_ACCESS_KEY_ID"], let secret = env["AWS_SECRET_ACCESS_KEY"] else {
            throw XCTSkip("Set AA_CLOUD_TEST=1 and AWS credentials to test the cloud AI.")
        }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let data = try? Data(contentsOf: repo.appendingPathComponent("Resources/CloudConfig.json")),
              let config = try? JSONDecoder().decode(CloudConfig.self, from: data) else {
            throw XCTSkip("No Resources/CloudConfig.json (run scripts/deploy_cloud.sh).")
        }
        let creds = AWSCredentials(accessKeyId: key, secretAccessKey: secret, sessionToken: env["AWS_SESSION_TOKEN"], expiration: .distantFuture)
        let model = try XCTUnwrap(CloudModel(config: config) { creds })
        let home = try TestHome()
        let answerer = Answerer(profile: Fixture.profile, db: home.db, ai: AIService(model: FakeModel()), helper: AIService(model: model))
        let job = JobContext(title: "Backend Engineer", company: "Initech", location: "Austin, TX (hybrid)",
                             description: "Python and AWS services. Hybrid: three days a week in our Austin office.")
        let fields = [
            field("Which of these languages do you know best?", .select, ["Go", "Python", "Rust"], id: "f_lang"),
            field("Is this role hybrid?", .radio, ["Yes", "No"], id: "f_hybrid"),
            field("Have you ever been convicted of a felony?", .radio, ["Yes", "No"], id: "f_felony"),
        ]
        let started = Date()
        let res = await answerer.resolve(fields, job: job)
        print("cloud AI (\(model.displayName)) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s:", res.answers, res.sources)
        XCTAssertEqual(res.answers["f_lang"], "Python")
        XCTAssertEqual(res.sources["f_lang"], "cloud:high")
        XCTAssertEqual(res.answers["f_hybrid"], "Yes")
        XCTAssertNil(res.answers["f_felony"], "never guessed, by either AI")
    }

    static let config = CloudConfig(region: "us-east-1", userPoolId: "p", clientId: "c", signInHost: "h", identityPoolId: "i", browserId: "b",
                                    browserProfileId: "f", signInProviders: nil, helperFunction: "auto-applicator-form-helper",
                                    helperModel: "us.amazon.nova-2-lite-v1:0")
}

/// Answers a URLSession's requests in the test: (status, body, headers) for each request and its body.
final class Stub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, Data) throws -> (Int, String, [String: String]))?

    static func session(_ handler: @escaping (URLRequest, Data) throws -> (Int, String, [String: String])) -> URLSession {
        Stub.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        do {
            let (status, text, headers) = try Stub.handler!(request, body)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}
