import AppKit
import WebKit
import XCTest
@testable import Engine

@MainActor
class FormTests: XCTestCase {
    var web: WebAgent!

    override func setUp() async throws {
        _ = NSApplication.shared
        web = try await makeWeb()
    }

    /// The browser under test: the built-in one here; `Cloud…Tests` use the cloud browser.
    func makeWeb() async throws -> WebAgent { WebAgent() }

    override func tearDown() async throws {
        await web?.cloud?.stop(saveProfile: false)
        web?.close()
        web = nil
    }

    func open(_ name: String, query: String = "") async throws {
        try await web.openFixture(name, query: query)
    }

    func testExtractGenericForm() async throws {
        try await open("generic_form.html")
        let fields = await web.extractFields(root: "#app-form")
        let by = Dictionary(fields.map { ($0.spec.label, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(by["First Name *"]?.kind, .text)
        XCTAssertEqual(by["First Name *"]?.spec.required, true)
        XCTAssertEqual(by["Email *"]?.spec.currentValue, "prefilled@example.com")
        let years = by["How many years of experience do you have with Python?"]
        XCTAssertEqual(years?.spec.type, .number)
        XCTAssertEqual(years?.spec.required, true)
        XCTAssertEqual(by["Why do you want to work here?"]?.spec.maxLength, 500)
        let auth = by["Are you legally authorized to work in the United States? *"]
        XCTAssertEqual(auth?.kind, .select)
        XCTAssertEqual(auth?.spec.options, ["Select...", "Yes", "No"])
        XCTAssertEqual(auth?.spec.currentValue, "")
        let spons = by["Will you now or in the future require sponsorship?"]
        XCTAssertEqual(spons?.kind, .radio)
        XCTAssertEqual(spons?.spec.options, ["Yes", "No"])
        XCTAssertEqual(spons?.spec.required, true)
        XCTAssertEqual(by["Which languages do you use?"]?.kind, .checkboxGroup)
        XCTAssertEqual(by["Which languages do you use?"]?.spec.options, ["Python", "Go", "Rust"])
        XCTAssertEqual(by["Gender"]?.kind, .combobox)
        XCTAssertEqual(by["Gender"]?.spec.options, ["Male", "Female", "Non-binary", "I don't wish to answer"])
        XCTAssertEqual(by["Do you have a valid driver's license?"]?.kind, .buttons)
        XCTAssertEqual(by["Resume/CV *"]?.kind, .file)
        XCTAssertEqual(by["Resume/CV *"]?.fileKind, "resume")
        XCTAssertEqual(by["I certify that the information provided is accurate *"]?.kind, .checkbox)
        XCTAssertNil(by["Hidden question"])
        XCTAssertEqual(fields.count, 12, fields.map(\.spec.label).joined(separator: " | "))
        let again = await web.extractFields(root: "#app-form", readOptions: false)
        XCTAssertEqual(again.map(\.id), fields.map(\.id))
    }

    func testFillAndSubmitWithErrorFeedback() async throws {
        try await open("generic_form.html")
        let fields = Dictionary(await web.extractFields(root: "#app-form").map { ($0.spec.label, $0) }, uniquingKeysWith: { a, _ in a })
        func f(_ label: String) -> FormField { fields[label]! }
        let ok1 = await web.fill(f("First Name *"), "Jane")
        XCTAssertTrue(ok1)
        let button = await web.findButton("^submit", root: "#app-form")
        XCTAssertNotNil(button)
        await web.clickFoundButton()
        try await web.sleep(0.3)
        let native = await web.collectErrors(root: "#app-form")
        XCTAssertNotNil(native[f("Last Name *").id])
        XCTAssertNil(native[f("First Name *").id])

        for (label, value) in [("Last Name *", "Doe"), ("How many years of experience do you have with Python?", "six"),
                               ("Are you legally authorized to work in the United States? *", "Yes"),
                               ("Will you now or in the future require sponsorship?", "No"), ("Which languages do you use?", "Python ; Rust"),
                               ("Gender", "I don't wish to answer"), ("Do you have a valid driver's license?", "Yes"),
                               ("I certify that the information provided is accurate *", "Yes")] {
            let ok = await web.fill(f(label), value)
            XCTAssertTrue(ok, label)
        }
        let resume = FileManager.default.temporaryDirectory.appendingPathComponent("resume.pdf")
        try Data("%PDF-1.4".utf8).write(to: resume)
        let uploaded = await web.upload(f("Resume/CV *"), resume)
        XCTAssertTrue(uploaded)

        let values = try await web.js("""
            return {fn: document.getElementById('fn').value, auth: document.getElementById('auth').value,
                    spn: document.getElementById('sp-n').checked, l1: document.querySelector('input[name=lang1]').checked,
                    l2: document.querySelector('input[name=lang2]').checked, l3: document.querySelector('input[name=lang3]').checked,
                    cmb: document.getElementById('cmb').value, yes: document.querySelector('.yesno button').getAttribute('aria-pressed'),
                    agree: document.getElementById('agree').checked, files: document.getElementById('resume').files.length}
            """) as? [String: Any]
        XCTAssertEqual(values?["fn"] as? String, "Jane")
        XCTAssertEqual(values?["auth"] as? String, "Yes")
        XCTAssertEqual(values?["spn"] as? Bool, true)
        XCTAssertEqual(values?["l1"] as? Bool, true)
        XCTAssertEqual(values?["l2"] as? Bool, false)
        XCTAssertEqual(values?["l3"] as? Bool, true)
        XCTAssertEqual(values?["cmb"] as? String, "I don't wish to answer")
        XCTAssertEqual(values?["yes"] as? String, "true")
        XCTAssertEqual(values?["agree"] as? Bool, true)
        XCTAssertEqual((values?["files"] as? NSNumber)?.intValue, 1)

        let button2 = await web.findButton("^submit", root: "#app-form")
        XCTAssertNotNil(button2)
        await web.clickFoundButton()
        try await web.sleep(0.3)
        let errors = await web.collectErrors(root: "#app-form")
        let yrsID = f("How many years of experience do you have with Python?").id
        XCTAssertEqual(errors, [yrsID: "Enter a whole number"])
        let refreshed = Dictionary(await web.extractFields(root: "#app-form", readOptions: false).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(refreshed[yrsID]?.spec.error, "Enter a whole number")
        let fixed = await web.fill(refreshed[yrsID]!, "6")
        XCTAssertTrue(fixed)
        let button3 = await web.findButton("^submit", root: "#app-form")
        XCTAssertNotNil(button3)
        await web.clickFoundButton()
        try await web.sleep(0.3)
        let text = await web.text()
        XCTAssertTrue(text.contains("Thank you for applying"), text)
    }

    /// Clicks are real mouse events (pages that ignore synthetic clicks still respond).
    func testClicksAreTrusted() async throws {
        try await web.loadTestHTML("""
            <button id=b style="margin:300px">Go</button><input id=i>
            <script>window.log=[]; b.addEventListener('click', e => log.push('click:' + e.isTrusted));
            b.addEventListener('mousedown', e => log.push('down:' + e.isTrusted));</script>
            """, base: URL(string: "https://example.com/")!)
        let clicked = await web.click("#b")
        XCTAssertTrue(clicked)
        let log = try await web.js("return window.log", world: .page) as? [String]
        XCTAssertEqual(log, ["down:true", "click:true"])
    }

    /// Values set by the automation reach React's state (React ignores plain `el.value = …`).
    func testReactControlledInput() async throws {
        try await web.loadTestHTML("""
            <input id=name>
            <script>
            // React's value tracker in miniature: it records the value through the element's own setter and only
            // fires onChange when the DOM value differs from the tracked one.
            const el = document.getElementById('name'); let tracked = '';
            const proto = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
            Object.defineProperty(el, 'value', {get() { return proto.get.call(this); }, set(v) { tracked = v; proto.set.call(this, v); }});
            window.state = '';
            el.addEventListener('input', () => { const v = proto.get.call(el); if (v !== tracked) { tracked = v; window.state = v; } });
            </script>
            """, base: URL(string: "https://example.com/")!)
        let filled = await web.fill("#name", "Jane Doe")
        XCTAssertTrue(filled)
        let state = try await web.js("return window.state", world: .page) as? String
        XCTAssertEqual(state, "Jane Doe")
    }

    func testVirtualListHydratesAllCards() async throws {
        try await open("search.html")
        let before = LinkedIn.cards(from: try await web.js(Scripts.jobCards))
        XCTAssertLessThan(before.filter { !$0.title.isEmpty }.count, 25)
        _ = try await web.js(Scripts.scrollJobList, ["step": 300])
        let cards = LinkedIn.cards(from: try await web.js(Scripts.jobCards))
        XCTAssertEqual(cards.count, 25)
        XCTAssertTrue(cards.allSatisfy { !$0.title.isEmpty && !$0.company.isEmpty })
        XCTAssertEqual(cards[3].company, "BadCorp")
        XCTAssertTrue(cards[5].applied)
        XCTAssertFalse(cards[4].applied)
        XCTAssertEqual(cards[0].url.absoluteString, "https://www.linkedin.com/jobs/view/4000000000/")
    }

    func testPDFEvidence() async throws {
        try await open("generic_form.html")
        let pdf = await web.pdf()
        XCTAssertEqual(pdf.map { String(decoding: $0.prefix(4), as: UTF8.self) }, "%PDF")
    }
}

/// The same tests, run in the cloud browser (needs AA_CLOUD_TEST=1 and AWS credentials; skipped otherwise).
final class CloudFormTests: FormTests {
    override func makeWeb() async throws -> WebAgent { try await makeCloudTestAgent() }
}
