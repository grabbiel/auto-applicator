import AppKit
import WebKit
import XCTest
@testable import Engine

@MainActor
class HandlerTests: XCTestCase {
    var web: WebAgent!
    var home: TestHome!
    var steps: [String] = []

    override func setUp() async throws {
        _ = NSApplication.shared
        web = try await makeWeb()
        home = try TestHome()
        steps = []
    }

    /// The browser under test: the built-in one here; `Cloud…Tests` use the cloud browser.
    func makeWeb() async throws -> WebAgent { WebAgent() }

    override func tearDown() async throws {
        await web?.cloud?.stop(saveProfile: false)
        web?.close()
        web = nil
        home = nil
    }

    func open(_ name: String, query: String = "") async throws {
        try await web.openFixture(name, query: query)
    }

    func page(_ expr: String) async throws -> Any? { try await web.js("return \(expr)", world: .page) }

    func context(_ model: FakeModel, practice: Bool, verifier: EmailVerifier? = nil) -> ApplyContext {
        let ai = AIService(model: model)
        var settings = Store(paths: home.paths).loadSettings()
        settings.practiceMode = practice
        return ApplyContext(jobID: "4242", job: Fixture.job, settings: settings, paths: home.paths, profile: Fixture.profile, db: home.db,
                            answerer: Answerer(profile: Fixture.profile, db: home.db, ai: ai), ai: ai,
                            verifier: verifier ?? EmailVerifier(secrets: Secrets(), ai: nil), secrets: Secrets(), practice: practice) { [weak self] in
            self?.steps.append($0)
        }
    }

    /// The job page's Easy Apply button is found and tagged the way a run does it.
    func openEasyApply(query: String = "") async throws {
        try await open("easy_apply.html", query: query)
        let details = try await web.readJobDetails()
        XCTAssertEqual(details.kind, .easyApply)
        XCTAssertTrue(details.description.contains("Python"), details.description)
    }

    static let easyModel = { FakeModel(feedback: ["start date": ("12/01/2026", .high)]) }

    func testEasyApplyPracticeStopsBeforeSubmit() async throws {
        try await openEasyApply()
        let result = try await EasyApplyHandler(web: web, ctx: context(Self.easyModel(), practice: true)).apply()
        XCTAssertEqual(result.status, .practiceComplete, result.notes)
        XCTAssertNotNil(result.evidence)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.evidence!.path))
        let submitted = try await page("window.__submitted") as? Bool
        let discarded = try await page("window.__discarded") as? Bool
        XCTAssertEqual(submitted, false)
        XCTAssertEqual(discarded, true)
    }

    func testEasyApplySubmitsAndFixesValidation() async throws {
        try await openEasyApply()
        let model = Self.easyModel()
        let result = try await EasyApplyHandler(web: web, ctx: context(model, practice: false)).apply()
        XCTAssertEqual(result.status, .applied, result.notes)
        let submitted = try await page("window.__submitted") as? Bool
        let follow = try await page("window.__followAtSubmit") as? Bool
        XCTAssertEqual(submitted, true)
        XCTAssertEqual(follow, false, "the follow-company box is unticked")
        XCTAssertTrue(model.feedback.contains { $0.contains { $0.contains("MM/DD/YYYY") } }, "the rejected date went back to the AI with the error")
    }

    func testEasyApplyUnknownQuestionIsSavedForTheUser() async throws {
        try await openEasyApply(query: "?extra=rust")
        let model = FakeModel(["rust": ("1", .low)], feedback: ["start date": ("12/01/2026", .high)])
        let result = try await EasyApplyHandler(web: web, ctx: context(model, practice: false)).apply()
        XCTAssertEqual(result.status, .needsAnswer)
        XCTAssertTrue(result.notes.contains("Rust"), result.notes)
        let submitted = try await page("window.__submitted") as? Bool
        let discarded = try await page("window.__discarded") as? Bool
        XCTAssertEqual(submitted, false)
        XCTAssertEqual(discarded, true)
        let pending = home.db.listPending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.jobIDs, ["4242"])
    }

    func testGreenhouseSubmitsWithEmailedSecurityCode() async throws {
        try await open("greenhouse.html")
        var secrets = Secrets()
        (secrets.imapUser, secrets.imapPassword, secrets.imapHost) = ("jane.doe@example.com", "abcdabcdabcdabcd", "imap.example.com")
        let box = FakeMailbox([])
        // the code arrives once the form has been submitted
        box.onRefresh = { [unowned box] in if box.messages.isEmpty { box.messages.append((1, email("greenhouse"), false)) } }
        let verifier = EmailVerifier(secrets: secrets, ai: nil, pollInterval: 0.05) { _ in box }
        let result = try await GreenhouseHandler(web: web, ctx: context(FakeModel(), practice: false, verifier: verifier)).apply()
        XCTAssertEqual(result.status, .applied, result.notes)
        let finals = try await page("window.__finalSubmit") as? NSNumber
        XCTAssertEqual(finals?.intValue, 1)
        let text = await web.text()
        XCTAssertTrue(text.contains("Thank you for applying"), text)
    }

    func testGreenhousePracticeFillsWithoutSubmitting() async throws {
        try await open("greenhouse.html")
        let result = try await GreenhouseHandler(web: web, ctx: context(FakeModel(), practice: true)).apply()
        XCTAssertEqual(result.status, .practiceComplete, result.notes)
        let values = try await page("""
            ({first: document.getElementById('first_name').value, email: document.getElementById('email').value,
              q1: document.getElementById('question_1').value, q2: document.getElementById('question_2').value,
              gender: document.getElementById('gender').value, files: document.getElementById('resume').files.length})
            """) as? [String: Any]
        XCTAssertEqual(values?["first"] as? String, "Jane")
        XCTAssertEqual(values?["email"] as? String, "jane.doe@example.com")
        XCTAssertEqual(values?["q1"] as? String, "https://www.linkedin.com/in/janedoe")
        XCTAssertEqual(values?["q2"] as? String, "No")
        XCTAssertEqual(values?["gender"] as? String, "Decline To Self Identify")
        XCTAssertEqual((values?["files"] as? NSNumber)?.intValue, 1)
    }

    func testGenericSiteEndToEnd() async throws {
        try await open("generic_form.html")
        let model = FakeModel(["why do you want": ("I like building reliable Python services.", .medium), "driver": ("Yes", .high),
                               "languages": ("Python ; Rust", .high), "certify": ("Yes", .high)])
        let result = try await GenericHandler(web: web, ctx: context(model, practice: false)).apply()
        XCTAssertEqual(result.status, .applied, result.notes)
        let text = await web.text()
        XCTAssertTrue(text.contains("Thank you for applying"), text)
        XCTAssertTrue(steps.contains("Attached your resume"), steps.joined(separator: " | "))
    }

    func testCoverLetterPDF() throws {
        let data = try PDFWriter.letter(String(repeating: "A paragraph about why I'd be a great fit. ", count: 200), title: "Cover letter")
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "%PDF")
        XCTAssertGreaterThan(data.count, 2000)
    }
}

/// The same tests, run in the cloud browser (needs AA_CLOUD_TEST=1 and AWS credentials; skipped otherwise).
final class CloudHandlerTests: HandlerTests {
    override func makeWeb() async throws -> WebAgent { try await makeCloudTestAgent() }
}
