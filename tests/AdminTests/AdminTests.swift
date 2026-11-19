import XCTest
@testable import AdminKit

/// The admin tool's reading of the AWS CLI's replies (made-up accounts; nothing here calls AWS).
final class AdminTests: XCTestCase {
    static let users = #"""
    {"Users": [
      {"Username": "u1", "Enabled": true, "UserStatus": "CONFIRMED", "UserCreateDate": "2026-11-13T15:26:04.517585+00:00",
       "Attributes": [{"Name": "sub", "Value": "11111111-aaaa-4bbb-8ccc-000000000001"}, {"Name": "email", "Value": "owner@example.com"},
                      {"Name": "email_verified", "Value": "true"},
                      {"Name": "identities", "Value": "[{\"userId\":\"123\",\"providerName\":\"SignInWithApple\"},{\"userId\":\"9\",\"providerName\":\"Google\"}]"},
                      {"Name": "custom:browser", "Value": "auto_applicator_browser-Q0aaaaaaaa"}, {"Name": "custom:profile", "Value": "auto_applicator_profile-skaaaaaaaa"}]},
      {"Username": "u2", "Enabled": true, "UserStatus": "FORCE_CHANGE_PASSWORD", "UserCreateDate": "2026-11-18T09:00:00+00:00",
       "Attributes": [{"Name": "sub", "Value": "22222222-aaaa-4bbb-8ccc-000000000002"}, {"Name": "email", "Value": "new@example.com"},
                      {"Name": "custom:browser", "Value": "aa_22222222aaaa4bbb8ccc000000000002-Xy12345678"},
                      {"Name": "custom:profile", "Value": "aa_22222222aaaa4bbb8ccc000000000002-Zw12345678"}]},
      {"Username": "u3", "Enabled": false, "UserStatus": "CONFIRMED", "UserCreateDate": "2026-11-01T09:00:00.1+00:00",
       "Attributes": [{"Name": "sub", "Value": "33333333-aaaa-4bbb-8ccc-000000000003"}, {"Name": "email", "Value": "former@example.com"}]},
      {"Username": "Google_9", "Enabled": true, "UserStatus": "EXTERNAL_PROVIDER",
       "Attributes": [{"Name": "sub", "Value": "44444444-aaaa-4bbb-8ccc-000000000004"}, {"Name": "email", "Value": "owner@example.com"}]}
    ]}
    """#

    func testReadsPeople() {
        let allowed = Person.ids(Data(#"{"Users": [{"Attributes": [{"Name": "sub", "Value": "11111111-aaaa-4bbb-8ccc-000000000001"}]}]}"#.utf8))
        let people = Person.list(Data(Self.users.utf8), allowedAI: allowed)
        XCTAssertEqual(people.map(\.email), ["former@example.com", "owner@example.com", "new@example.com"], "oldest first; a joined Google sign-in isn't a person")

        let owner = people[1]
        XCTAssertEqual(owner.state, .active)
        XCTAssertEqual(owner.linked, ["Apple", "Google"])
        XCTAssertEqual(owner.signsInWith, "Signs in with password or passkey, Apple, Google")
        XCTAssertTrue(owner.cloudAI)
        XCTAssertTrue(owner.hasOwnBrowser)
        XCTAssertEqual(owner.browserId, "auto_applicator_browser-Q0aaaaaaaa")

        let new = people[2]
        XCTAssertEqual(new.state, .invited)
        XCTAssertEqual(new.signsInWith, "Invited, not signed in yet")
        XCTAssertFalse(new.cloudAI, "the cloud AI is off until it's turned on for someone")

        let former = people[0]
        XCTAssertEqual(former.state, .revoked)
        XCTAssertFalse(former.hasOwnBrowser)
        XCTAssertNotNil(former.created, "a time with one decimal still reads")
    }

    func testReadsSessionsAndUsage() {
        let now = AWSJSON.date("2026-11-19T12:00:00+00:00")!
        let sessions = BrowserSession.list(Data(#"""
        {"items": [
          {"sessionId": "old", "status": "TERMINATED", "createdAt": "2026-11-01T10:00:00.000001+00:00", "lastUpdatedAt": "2026-11-01T12:00:00+00:00"},
          {"sessionId": "live", "status": "READY", "createdAt": "2026-11-19T11:30:00.709008+00:00", "lastUpdatedAt": "2026-11-19T11:30:05+00:00"},
          {"sessionId": "done", "status": "TERMINATED", "createdAt": "2026-11-18T10:00:00+00:00", "lastUpdatedAt": "2026-11-18T11:30:00+00:00"}
        ]}
        """#.utf8))
        XCTAssertEqual(sessions.map(\.id), ["live", "done", "old"], "newest first")
        var person = Person(id: "1", email: "a@example.com", state: .active, sessions: sessions)
        XCTAssertEqual(person.running.map(\.id), ["live"])
        XCTAssertEqual(person.lastUsed, sessions[0].started)
        let week = person.usage(days: 7, now: now)
        XCTAssertEqual(week.sessions, 2)
        XCTAssertEqual(week.hours, 2.0, accuracy: 0.001, "an hour and a half finished, half an hour running so far")
        person.sessions = []
        XCTAssertNil(person.lastUsed)
        XCTAssertEqual(person.usage(now: now).sessions, 0)
    }

    func testReadsTheStack() throws {
        let data = Data(#"""
        {"Stacks": [{"StackName": "auto-applicator-cloud", "StackStatus": "UPDATE_COMPLETE", "CreationTime": "2026-11-13T15:20:00+00:00",
          "LastUpdatedTime": "2026-11-19T08:00:00.5+00:00",
          "Parameters": [{"ParameterKey": "GoogleSignIn", "ParameterValue": "true"}, {"ParameterKey": "AppleSignIn", "ParameterValue": "false"},
                         {"ParameterKey": "PlaceAttributes", "ParameterValue": "true"}],
          "Outputs": [{"OutputKey": "UserPoolId", "OutputValue": "us-east-1_EXAMPLE"}, {"OutputKey": "CloudAIGroup", "OutputValue": "cloud-ai"},
                      {"OutputKey": "HelperFunction", "OutputValue": "auto-applicator-form-helper"}]}]}
        """#.utf8)
        let stack = try XCTUnwrap(CloudStack.read(data))
        XCTAssertTrue(stack.healthy)
        XCTAssertFalse(stack.busy)
        XCTAssertTrue(stack.perPerson)
        XCTAssertEqual(stack.providers, ["Google"])
        XCTAssertEqual(stack.userPoolId, "us-east-1_EXAMPLE")
        XCTAssertEqual(stack.updated, AWSJSON.date("2026-11-19T08:00:00+00:00"))

        // From before each person had a browser of their own.
        var shared = stack
        shared.outputs["CloudAIGroup"] = nil
        shared.status = "UPDATE_IN_PROGRESS"
        XCTAssertFalse(shared.perPerson)
        var half = stack
        half.parameters["PlaceAttributes"] = "false"
        XCTAssertFalse(half.perPerson, "the app can't read which browser is its own until this is on")
        XCTAssertTrue(shared.busy)
        XCTAssertNil(CloudStack.read(Data("{}".utf8)))
    }

    /// What `--tidy` would delete: people's browsers and profiles whose account is gone, never anything else.
    func testFindsWhatNoAccountUses() {
        let places = Places.read(
            browsers: Data(#"""
            {"browserSummaries": [{"browserId": "aa_22222222aaaa4bbb8ccc000000000002-Xy12345678", "name": "aa_22222222aaaa4bbb8ccc000000000002"},
                                  {"browserId": "aa_99999999aaaa4bbb8ccc000000000009-Gone000000", "name": "aa_99999999aaaa4bbb8ccc000000000009"},
                                  {"browserId": "auto_applicator_browser-Q0aaaaaaaa", "name": "auto_applicator_browser"},
                                  {"browserId": "aa_tests-T000000000", "name": "aa_tests"},
                                  {"browserId": "someone_elses-B000000000", "name": "someone_elses"}]}
            """#.utf8),
            profiles: Data(#"""
            {"profileSummaries": [{"profileId": "aa_22222222aaaa4bbb8ccc000000000002-Zw12345678", "name": "aa_22222222aaaa4bbb8ccc000000000002"},
                                  {"profileId": "aa_99999999aaaa4bbb8ccc000000000009-Gone111111", "name": "aa_99999999aaaa4bbb8ccc000000000009"}]}
            """#.utf8))
        XCTAssertEqual(places.browsers.count, 5)
        XCTAssertTrue(places.hasTestBrowser)
        let people = Person.list(Data(Self.users.utf8))
        XCTAssertEqual(places.unused(by: people), ["aa_99999999aaaa4bbb8ccc000000000009-Gone000000", "aa_99999999aaaa4bbb8ccc000000000009-Gone111111"])
        XCTAssertEqual(Places().unused(by: people), [])
    }

    func testReadsTheBill() {
        let cost = Cost.read(Data(#"""
        {"ResultsByTime": [{"Groups": [
          {"Keys": ["AWS Lambda"], "Metrics": {"UnblendedCost": {"Amount": "0.0213", "Unit": "USD"}}},
          {"Keys": ["Amazon Bedrock AgentCore"], "Metrics": {"UnblendedCost": {"Amount": "4.8201", "Unit": "USD"}}},
          {"Keys": ["Amazon Cognito"], "Metrics": {"UnblendedCost": {"Amount": "0.0000001", "Unit": "USD"}}}]}]}
        """#.utf8))
        XCTAssertEqual(cost.services.map(\.name), ["Amazon Bedrock AgentCore", "AWS Lambda"], "biggest first, without what cost nothing")
        XCTAssertEqual(cost.total, 4.8414, accuracy: 0.0001)
        XCTAssertEqual(cost.currency, "USD")
    }

    func testKnowsAnExpiredSignIn() {
        XCTAssertTrue(CloudAdmin.isSignedOut("aws: [ERROR]: Error when retrieving token from sso: Token has expired and refresh failed"))
        XCTAssertTrue(CloudAdmin.isSignedOut("Unable to locate credentials. You can configure credentials by running \"aws login\"."))
        XCTAssertTrue(CloudAdmin.isSignedOut("An error occurred (ExpiredToken) when calling the GetCallerIdentity operation"))
        XCTAssertFalse(CloudAdmin.isSignedOut("An error occurred (ValidationError) when calling the DescribeStacks operation: Stack with id x does not exist"))
        XCTAssertFalse(CloudAdmin.isSignedOut("An error occurred (AccessDeniedException) when calling the ListUsers operation"))
    }

    /// CloudFormation hands a template back with "?" for every arrow and dash; that isn't a change waiting to be deployed.
    func testComparesTemplatesTheWayAWSHandsThemBack() {
        let local = "Description: open Settings \u{2192} Cloud browser \u{2014} then sign in\n"
        let deployed = "Description: open Settings ? Cloud browser ? then sign in\n\n"
        XCTAssertEqual(CloudAdmin.asCloudFormationShowsIt(local), CloudAdmin.asCloudFormationShowsIt(deployed))
        XCTAssertNotEqual(CloudAdmin.asCloudFormationShowsIt(local + "Extra: 1\n"), CloudAdmin.asCloudFormationShowsIt(deployed))
    }

    func testRunsACommandAndFollowsItsLines() async throws {
        final class Lines: @unchecked Sendable {
            private let lock = NSLock()
            private var all: [String] = []
            func add(_ line: String) { lock.lock(); all.append(line); lock.unlock() }
            var value: [String] { lock.lock(); defer { lock.unlock() }; return all }
        }
        let lines = Lines()
        let result = try await Shell.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo one; echo two >&2; printf three; exit 3"],
                                         environment: ["AA_X": "y"]) { lines.add($0) }
        XCTAssertEqual(result.status, 3)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.output, "one\nthree")
        XCTAssertEqual(result.errors, "two\n")
        XCTAssertEqual(Set(lines.value), ["one", "two", "three"])
    }

    func testSettingsKeepTheirDefaultsForWhatAFileLeavesOut() throws {
        let settings = try JSONDecoder().decode(AdminSettings.self, from: Data(#"{"profile": "work"}"#.utf8))
        XCTAssertEqual(settings.profile, "work")
        XCTAssertEqual(settings.region, "us-east-1")
        XCTAssertEqual(settings.stack, "auto-applicator-cloud")
        XCTAssertTrue(settings.script.path.hasSuffix("scripts/deploy_cloud.sh"))
    }
}
