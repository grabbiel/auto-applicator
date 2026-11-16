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

    /// LinkedIn's public results page, and a list with only links to each job.
    func testJobCardsInOtherLayouts() async throws {
        try await open("search_public.html")
        var exists = await web.exists(Scripts.jobCardSelector)
        XCTAssertTrue(exists)
        var cards = LinkedIn.cards(from: try await web.js(Scripts.jobCards))
        XCTAssertEqual(cards.map(\.id), ["4480489824", "4461543800"])
        XCTAssertEqual(cards[0].title, "iOS Software Engineer III")
        XCTAssertEqual(cards[0].company, "Verily Health")
        XCTAssertEqual(cards[0].location, "Boston, Massachusetts, Estados Unidos")
        XCTAssertFalse(cards[0].applied)

        try await open("search_links.html")
        exists = await web.exists(Scripts.jobCardSelector)
        XCTAssertTrue(exists)
        cards = LinkedIn.cards(from: try await web.js(Scripts.jobCards))
        XCTAssertEqual(cards.map(\.id), ["4100000001", "4100000002", "4100000003"])
        XCTAssertEqual(cards.map(\.title), ["Senior iOS Engineer", "Desarrollador iOS", "Mobile Engineer"])
        XCTAssertEqual(cards.map(\.company), ["Acme", "Globex", "Initech"])
        XCTAssertEqual(cards.map(\.location), ["Austin, Texas, United States (On-site)", "Nueva York, Nueva York, Estados Unidos", "Remote"])
        XCTAssertEqual(cards.map(\.applied), [false, true, false])
    }

    /// LinkedIn's AI results page (where its job search now leads): its cards, and its pager, which swaps the list in place.
    func testAIResultsPage() async throws {
        try await open("search_ai.html")
        let exists = await web.waitFor(Scripts.jobCardSelector, timeout: 5)  // as a run does: the list draws itself
        XCTAssertTrue(exists)
        var cards = LinkedIn.cards(from: try await web.js(Scripts.jobCards))
        XCTAssertEqual(cards.map(\.id), ["4489300026", "4489300027", "4489300028"])
        XCTAssertEqual(cards.map(\.title), ["Java Full-Stack Developer", "Applied Scientist", "Senior Software Engineer"])
        XCTAssertEqual(cards.map(\.company), ["BeaconFire Inc.", "Applied Materials", "Initech"])
        XCTAssertEqual(cards.map(\.location), ["California, United States (Hybrid)", "Austin, TX (On-site)", "United States (Remote)"])
        XCTAssertEqual(cards.map(\.applied), [false, false, true])

        var shown = try await web.showResultsPage(1)
        XCTAssertTrue(shown)
        shown = try await web.showResultsPage(2)
        XCTAssertTrue(shown)
        cards = LinkedIn.cards(from: try await web.js(Scripts.jobCards))
        XCTAssertEqual(cards.map(\.id), ["4489300031", "4489300032"])
        XCTAssertEqual(cards.map(\.applied), [false, false])
        shown = try await web.showResultsPage(3)
        XCTAssertTrue(shown)
        cards = LinkedIn.cards(from: try await web.js(Scripts.jobCards))
        XCTAssertEqual(cards.map(\.id), ["4489300041"])
        shown = try await web.showResultsPage(4)
        XCTAssertFalse(shown)

        // From the first page straight to the third (as after reopening the search).
        try await open("search_ai.html")
        shown = try await web.showResultsPage(3)
        XCTAssertTrue(shown)
        cards = LinkedIn.cards(from: try await web.js(Scripts.jobCards))
        XCTAssertEqual(cards.map(\.id), ["4489300041"])

        // The classic list pages by address: nothing to click.
        try await open("search.html")
        shown = try await web.showResultsPage(2)
        XCTAssertTrue(shown)
    }

    /// Dates, names and places say which part of the form they belong to; emailed-code boxes are told from zip codes.
    func testSectionsAndCodeBoxes() async throws {
        try await web.loadTestHTML("""
            <form><h2>Education</h2>
              <div class="field"><label for="s">School</label><input id="s"></div>
              <div class="field"><label for="em">End date month</label><select id="em"><option>Select</option><option>May</option></select></div>
              <h2>Employment</h2>
              <div class="field"><label for="c">Company name</label><input id="c"></div>
              <div class="field"><label for="otp">Verification code</label><input id="otp"></div>
              <div class="field"><label for="zip">Zip code</label><input id="zip"></div>
              <!-- Infosys: a <p> section title, labels with a leading "*", numbered names -->
              <div class="section-form"><p class="form-section-title">Work experience</p>
                <div class="row"><div class="form-group"><label class="main-label"><span>*</span>Start year</label><input id="sy" placeholder="Start year"></div></div></div>
              <div class="section-form">
                <div class="form-group"><label class="main-label">GPA *</label><input id="gpa"></div>
                <div class="form-group"><label class="main-label">End year</label><input id="ey" name="custom[education][0][end_year]"></div></div>
            </form>
            """, base: URL(string: "https://example.test/sections")!)
        let fields = await web.extractFields()
        let by = Dictionary(fields.map { ($0.spec.plainLabel, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(by["End date month"]?.spec.section, "Education")
        XCTAssertEqual(by["End date month"]?.spec.contextLabel, "Education › End date month")
        XCTAssertEqual(by["Company name"]?.spec.section, "Work experience")
        XCTAssertEqual(by["Verification code"]?.isEmailCode, true)
        XCTAssertEqual(by["Zip code"]?.isEmailCode, false)
        XCTAssertEqual(by["Start year"]?.spec.contextLabel, "Work experience › Start year", fields.map(\.spec.label).joined(separator: " | "))
        XCTAssertEqual(by["End year"]?.spec.contextLabel, "Education › End year")
        XCTAssertNotNil(by["GPA"], "no required marks in what's shown")
    }

    /// Eightfold (Lockheed Martin) marks its questions "one-time-code" so browsers don't fill them in: they're
    /// questions, not boxes for an emailed code.
    func testLabelledQuestionsMarkedOneTimeCodeAreQuestions() async throws {
        try await web.loadTestHTML("""
            <form>
              <div class="field"><label for="pn">Preferred Name</label><input id="pn" autocomplete="one-time-code"></div>
              <div class="field"><label for="sig">Please sign by typing your full legal name</label><input id="sig" autocomplete="one-time-code"></div>
              <div class="field"><label for="vc">Verification code</label><input id="vc" autocomplete="one-time-code"></div>
            </form>
            """, base: URL(string: "https://example.test/apply")!)
        let fields = await web.extractFields()
        let code = Dictionary(fields.map { ($0.spec.label, $0.isEmailCode) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(code["Preferred Name"], false, fields.map(\.spec.label).joined(separator: ", "))
        XCTAssertEqual(code["Please sign by typing your full legal name"], false)
        XCTAssertEqual(code["Verification code"], true)
        var bare = FormField(spec: field(""), kind: .text)
        bare.autocomplete = "one-time-code"
        XCTAssertTrue(bare.isEmailCode, "an unlabelled box marked one-time-code is for the code")
    }

    /// TCS's US form (Angular Material): "Select Title" is an empty list, not an answer; ~400 time zones are chosen
    /// by name; Skills is a search box (its class says so) that takes up to five chips, only real matches.
    func testAngularMaterialListsAndChips() async throws {
        try await web.openFixture("tcs_register.html")
        let fields = await web.extractFields()
        let by = Dictionary(fields.map { ($0.spec.label.replacingOccurrences(of: "*", with: "").trimmed, $0) }, uniquingKeysWith: { a, _ in a })
        guard let title = by["Title"], let tz = by["Preferred Timezone"], let skills = by["Skills"] else {
            return XCTFail(fields.map { "\($0.spec.label) (\($0.kind))" }.joined(separator: ", "))
        }
        XCTAssertEqual(title.spec.currentValue, "")
        XCTAssertEqual(title.spec.options, ["Dr.", "Mr.", "Ms."])
        XCTAssertTrue(tz.typeahead, "hundreds of zones: chosen by name, not listed for the AI")
        XCTAssertEqual(skills.kind, .combobox)
        XCTAssertTrue(skills.isInput)
        XCTAssertEqual(skills.spec.maxChoices, 5)
        let filledTitle = await web.fill(title, "Mr.")
        let filledZone = await web.fill(tz, "America/Chicago")
        let filledSkills = await web.fill(skills, "Python; AWS; Klingon; Go; Raleigh, NC")
        XCTAssertTrue(filledTitle)
        XCTAssertTrue(filledZone)
        XCTAssertTrue(filledSkills)
        await web.click("#next")
        let result = try await web.js("return JSON.parse(sessionStorage.getItem('tcsResult') || 'null')", world: .page) as? [String: Any]
        XCTAssertEqual(result?["title"] as? String, "Mr.")
        XCTAssertEqual(result?["tz"] as? String, "America/Chicago")
        XCTAssertEqual(result?["skills"] as? [String], ["Python", "AWS", "Raleigh, North Carolina"],
                       "no chip for a word the list doesn't have, nor for another that starts the same (Go → Google Cloud)")
        XCTAssertEqual(result?["typed"] as? String, "")
    }

    /// The names lists give a time zone.
    func testTimeZoneNamesInLists() {
        XCTAssertEqual(TimeZones.match("America/Chicago", ["(GMT-08:00) Pacific Time (US & Canada)", "(GMT-06:00) Central Time (US & Canada)"]),
                       "(GMT-06:00) Central Time (US & Canada)")
        XCTAssertEqual(TimeZones.match("America/Chicago", ["PST", "CST", "EST"]), "CST")
        XCTAssertEqual(TimeZones.match("America/Los_Angeles", ["US/Eastern", "US/Pacific"]), "US/Pacific")
        XCTAssertEqual(TimeZones.match("America/New_York", ["UTC-06:00 Chicago", "UTC-05:00 New York"]), "UTC-05:00 New York")
        XCTAssertNil(TimeZones.match("Over 18: true", ["CST"]))
    }

    /// Traps for robots are never read as questions: Workday's box clipped to a pixel, one placed off the page, one
    /// whose label tells robots apart. A real website box and a small search-as-you-type box still are.
    func testRobotTrapsAreNotQuestions() async throws {
        try await web.loadTestHTML("""
            <form>
              <div class="field"><label for="w">Website</label><input id="w" name="site"></div>
              <div style="position: relative"><label for="hp">Enter website. This input is for robots only, do not enter if you're human.</label>
                <input id="hp" data-automation-id="beecatcher" name="website" type="text"
                       style="position: absolute; width: 1px; height: 1px; clip: rect(1px, 1px, 1px, 1px); overflow: hidden"></div>
              <div><label for="clip">Company URL</label>
                <input id="clip" name="url2" style="position: absolute; width: 1px; height: 1px; clip-path: polygon(0px 0px, 0px 0px, 0px 0px, 0px 0px)"></div>
              <div style="position: absolute; left: -9999px"><label for="off">Fax</label><input id="off" name="fax" tabindex="-1"></div>
              <div class="field"><label for="trap">Leave this field blank</label><input id="trap" name="hp2"></div>
              <div class="field"><label for="city">City</label>
                <input id="city" role="combobox" aria-autocomplete="list" style="width: 2px; height: 1px"></div>
            </form>
            """, base: URL(string: "https://example.wd1.myworkdayjobs.com/apply")!)
        let labels = await web.extractFields().map(\.spec.label)
        XCTAssertEqual(labels, ["Website", "City"])
    }

    /// Paylocity (2026): a label wrapped around its list ("Country" around the box showing "United States"), a list of
    /// 240 countries that draws only the rows in view and doesn't narrow as you type, its aria-owns on the wrapper; a
    /// radio group inside a label; a Yes/No list whose choices show only once it's opened.
    func testLongListDrawingOnlyTheRowsInView() async throws {
        try await web.loadTestHTML("""
            <form>
              <label for="country"><span>Country</span><div id="wrap" aria-haspopup="listbox" aria-owns="clist" aria-expanded="false">
                <div class="input-select-input-single-value" id="sv">Peru</div><input id="country" type="text" aria-autocomplete="list" required value=""></div></label>
              <div id="clist" role="list" style="display: none"><div id="sc" style="height: 140px; overflow: auto; position: relative">
                <div id="tall" style="position: relative"></div></div></div>
              <label for="hear"><span class="radio">How did you hear about us?</span><div role="radiogroup" aria-required="true">
                <label><input type="radio" name="hear" value="Online Job Board">Online Job Board</label>
                <label><input type="radio" name="hear" value="Other">Other</label></div></label>
              <div class="form-group"><label>We may use SMS during the hiring process. Do you give us permission to text you?<em> (required)</em></label>
                <div id="sms" role="combobox" aria-owns="smslist" aria-haspopup="true" aria-expanded="false" tabindex="0"><div class="rw-input">--</div></div>
                <ul id="smslist" role="listbox"></ul></div>
            </form>
            <script>
            const names = []; for (let i = 0; i < 240; i++) names.push('Country ' + String(i).padStart(3, '0'));
            names[200] = 'United Kingdom'; names[201] = 'United States'; names[202] = 'United States Minor Outlying Islands';
            const ROW = 35, tall = document.getElementById('tall'), sc = document.getElementById('sc');
            tall.style.height = (names.length * ROW) + 'px';
            // Like React's lists, the rows are drawn again only when the rows in view change.
            let drawn = -1;
            const draw = () => {
              const first = Math.floor(sc.scrollTop / ROW);
              if (first === drawn) return; drawn = first;
              tall.innerHTML = names.slice(first, first + 5).map((n, k) =>
                `<div role="listitem" style="position: absolute; top: ${(first + k) * ROW}px; height: ${ROW}px">${n}</div>`).join('');
              tall.querySelectorAll('[role=listitem]').forEach(r => r.onclick = () => {
                document.getElementById('sv').innerText = r.innerText; window.__country = r.innerText;
                document.getElementById('clist').style.display = 'none';
              });
            };
            sc.onscroll = draw;
            document.getElementById('country').onclick = () => { document.getElementById('clist').style.display = ''; draw(); };
            document.getElementById('sms').onclick = () => {
              const l = document.getElementById('smslist');
              l.innerHTML = ['--', 'Yes*', 'No'].map(o => `<li role="option">${o}</li>`).join('');
              l.querySelectorAll('li').forEach(li => li.onclick = () => { document.querySelector('#sms .rw-input').innerText = li.innerText; l.innerHTML = ''; });
            };
            </script>
            """, base: URL(string: "https://recruiting.example.test/Recruiting/Jobs/Apply/1")!)
        let fields = await web.extractFields()
        XCTAssertEqual(fields.map(\.spec.label).first, "Country")
        XCTAssertEqual(fields.first?.spec.currentValue, "Peru", "the list shows its choice beside the empty box")
        XCTAssertTrue(fields.map(\.spec.label).contains("How did you hear about us?"), "\(fields.map(\.spec.label))")
        guard let country = fields.first(where: { $0.spec.label == "Country" }) else { return XCTFail("no Country") }
        let ok = await web.fill(country, "United States")
        let picked = try await web.js("return window.__country || ''", world: .page) as? String
        XCTAssertTrue(ok)
        XCTAssertEqual(picked, "United States")
        guard let sms = fields.first(where: { $0.spec.label.contains("permission to text") }) else { return XCTFail("no SMS") }
        XCTAssertEqual(ProfileRules.answer(Fixture.profile, sms.spec), "No", "texts are declined even before the list is read")
    }

    /// Workday's question lists: the button is named only "Select One Required"; the question is the label beside it.
    func testListButtonNamedSelectOneTakesTheQuestionBesideIt() async throws {
        try await web.loadTestHTML("""
            <form><div data-automation-id="formField-ai">
              <label for="other-id"><div><p>Do you consent to the use of AI on this application?</p></div><abbr title="required">*</abbr></label>
              <div><button type="button" aria-haspopup="listbox" aria-label="Select One Required" id="q1">Select One</button></div>
            </div></form>
            """, base: URL(string: "https://example.wd1.myworkdayjobs.com/apply")!)
        let labels = await web.extractFields().map(\.spec.label)
        XCTAssertEqual(labels.first.map { $0.hasPrefix("Do you consent to the use of AI") }, true, "\(labels)")
    }

    /// Workday announces "resume.pdf successfully uploaded" in an alert box: good news, not an error.
    func testGoodNewsIsNotAnError() async throws {
        try await web.loadTestHTML("""
            <form>
              <div class="field"><label for="r">Resume</label><input id="r"><div role="alert">resume.pdf successfully uploaded</div></div>
              <div class="field"><label for="c">Cover letter</label><input id="c"><div role="alert">The file could not be uploaded</div></div>
            </form>
            """, base: URL(string: "https://example.wd5.myworkdayjobs.com/apply")!)
        _ = await web.extractFields()
        let errors = await web.collectErrors()
        XCTAssertEqual(Array(errors.values), ["The file could not be uploaded"])
    }

    /// "Continue with GitHub" (IBM's sign-in) is never the form's Continue; Amazon's "Skip & continue" is.
    func testNeverPressesSocialSignInButtons() async throws {
        try await web.loadTestHTML("""
            <form><label for="e">Email</label><input id="e" type="email"><button type="button">Continue</button></form>
            <div><button>Continue with GitHub</button><button>Continue with Google</button><a href="#">Sign in with Apple</a></div>
            """, base: URL(string: "https://login.example.test/signin")!)
        let first = await web.findButton(nextPattern)
        XCTAssertEqual(first, "Continue")
        try await web.loadTestHTML("""
            <main><h2>Get SMS updates on your job applications</h2><button>Enable SMS updates</button><button>Skip & continue</button>
            <div><button>Continue with LinkedIn</button></div></main>
            """, base: URL(string: "https://account.example.test/apply/sms")!)
        let second = await web.findButton(nextPattern)
        XCTAssertEqual(second, "Skip & continue")
    }

    /// A select2 list whose schools come from the server as you type into the search box it opens (Infosys): the
    /// app types there, waits out "Searching…", and picks the school.
    func testSearchListThatLoadsAsYouType() async throws {
        try await web.loadTestHTML("""
            <form><div class="form-group"><label>* School / education institution</label>
              <select name="school" class="select2-hidden-accessible" aria-hidden="true" tabindex="-1"
                      style="position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)"></select>
              <span class="select2 select2-container" style="display:inline-block;width:300px"><span class="selection">
                <span class="select2-selection select2-selection--single" role="combobox" aria-haspopup="true" aria-expanded="false"
                      tabindex="0" aria-controls="rendered" style="display:block;height:30px;border:1px solid #999">
                  <span id="rendered" class="select2-selection__rendered" role="textbox" aria-readonly="true"></span></span></span></span>
            </div></form>
            <script>
            const SCHOOLS = ['Nevada Institute of Technology', 'Nevada State University', 'Reno State University', 'University of Nevada'];
            const sel = document.querySelector('select'), combo = document.querySelector('[role=combobox]');
            const close = () => { const d = document.querySelector('.select2-container--open'); if (d) d.remove(); combo.setAttribute('aria-expanded', 'false'); };
            document.addEventListener('keydown', e => { if (e.key === 'Escape') close(); });
            combo.addEventListener('click', () => {
              if (document.querySelector('.select2-container--open')) return;
              combo.setAttribute('aria-expanded', 'true');
              const drop = document.createElement('span');
              drop.className = 'select2-container select2-container--open';
              drop.style = 'position:absolute;left:10px;top:80px;width:300px;background:#fff;display:block';
              drop.innerHTML = '<span class="select2-search"><input class="select2-search__field" type="search" role="searchbox" aria-controls="results"></span>' +
                '<ul id="results" role="listbox"><li role="alert" class="select2-results__message">Please enter 1 or more characters</li></ul>';
              document.body.appendChild(drop);
              const input = drop.querySelector('input'), list = drop.querySelector('ul');
              input.focus();
              let timer;
              input.addEventListener('input', () => {
                list.innerHTML = '<li role="option" class="select2-results__option loading-results">Searching…</li>';
                clearTimeout(timer);
                timer = setTimeout(() => {
                  const word = input.value.toLowerCase().split(' ')[0];
                  const hits = SCHOOLS.filter(s => s.toLowerCase().includes(word));
                  list.innerHTML = hits.length ? hits.map(s => '<li role="option" class="select2-results__option">' + s + '</li>').join('')
                                               : '<li role="alert" class="select2-results__message">No results found</li>';
                }, 1500);
              });
              list.addEventListener('mouseup', e => {
                const li = e.target.closest('[role=option]');
                if (!li || /Searching/.test(li.textContent)) return;
                sel.innerHTML = '<option value="' + li.textContent + '" selected>' + li.textContent + '</option>';
                document.getElementById('rendered').textContent = li.textContent;
                close();
              });
            });
            </script>
            """, base: URL(string: "https://example.test/apply/education")!)
        let fields = await web.extractFields()
        guard let school = fields.first(where: { $0.kind == .combobox && $0.spec.label.contains("School") }) else {
            return XCTFail("no school list: \(fields.map { "\($0.kind) \($0.spec.label)" })")
        }
        let filled = await web.fill(school, "Nevada State University")
        XCTAssertTrue(filled)
        let value = try await web.js("return document.querySelector('select').value") as? String
        XCTAssertEqual(value, "Nevada State University")
    }

    /// An image puzzle (hCaptcha's "Click on items that are tied…", JPMorgan) is a bot check that never finishes by
    /// itself; a bare "We could not process your request" (Deloitte, to the cloud browser) is a site turning the
    /// app's browser away.
    func testPicturePuzzleAndBlockedPage() async throws {
        try await web.loadTestHTML("""
            <main><h1>Enter your email address.</h1><label for="e">Email Address</label><input id="e" type="email"><button>Next</button></main>
            <div style="position:fixed;left:20px;top:20px"><iframe title="hCaptcha challenge" style="width:400px;height:580px;border:0"
              src="https://newassets.hcaptcha.com/captcha/v1/abc/static/hcaptcha.html#frame=challenge&amp;id=0"></iframe></div>
            """, base: URL(string: "https://jobs.example.test/apply/email")!)
        let puzzle = await web.pageKind()
        XCTAssertEqual(puzzle.kind, .botcheck)
        XCTAssertTrue(puzzle.puzzle)
        let started = Date()
        let passed = await web.waitOutBotCheck(timeout: 20)
        XCTAssertFalse(passed)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "a puzzle isn't waited out")
        let note = await web.botCheckNote("jobs.example.test")
        XCTAssertTrue(note.contains("picture puzzle"), note)

        try await web.loadTestHTML("<h1>We could not process your request</h1><p>Please try again later.</p>",
                                   base: URL(string: "https://apply.example.test/careers/InviteToApply")!)
        let blocked = await web.pageKind()
        XCTAssertEqual(blocked.kind, .error)
        XCTAssertTrue(blocked.bare)
        let reach = try await SiteRouter.reachApplication(web, step: { _ in })
        guard case .stop(let why) = reach else { return XCTFail("went on") }
        XCTAssertTrue(why.contains("turn away automated browsers"), why)
    }

    func testBotCheckIsWaitedOut() async throws {
        try await web.loadTestHTML("""
            <body><h1>example.test</h1><p>Performing security verification</p>
            <p>This website uses a security service to protect against malicious bots.</p>
            <script>setTimeout(() => { document.body.innerHTML = '<form><label for=a>First name</label><input id=a>' +
              '<label for=b>Email</label><input id=b><label for=c>Phone</label><input id=c></form>'; }, 1500);</script></body>
            """, base: URL(string: "https://example.test/check")!)
        let first = await web.pageKind()
        XCTAssertEqual(first.kind, .botcheck)
        let passed = await web.waitOutBotCheck(timeout: 8)
        XCTAssertTrue(passed)
        let after = await web.pageKind()
        XCTAssertEqual(after.fields, 3)
    }

    /// Oracle's career sites hide the real checkbox (zero size, transparent) under a box they draw, whose click
    /// handler ticks it and cancels the click: ticking it ticks it once, and the terms link isn't followed.
    func testDrawnCheckboxIsTicked() async throws {
        try await web.loadTestHTML("""
            <form><h3>Enter your email address.</h3>
            <label class="row" for="terms" style="display:block; margin-top:200px">
              <input type="checkbox" id="terms" required style="position:absolute; opacity:0; width:0; height:0; margin:0">
              <span id="box" style="display:inline-block; width:22px; height:22px; border:1px solid #333"></span>
              <span>I agree with the <a href="https://example.com/terms" id="link">terms and conditions</a> *</span>
            </label></form>
            <script>
            window.accepted = false; window.followed = false;
            const input = document.getElementById('terms');
            // Like Knockout's click binding on the drawn box: toggles the model and cancels the click.
            document.getElementById('box').addEventListener('click', e => { window.accepted = !window.accepted; input.checked = window.accepted; e.preventDefault(); });
            // Like its checked binding on the real box: a click that reaches it (through the label) updates the model.
            input.addEventListener('click', () => setTimeout(() => { window.accepted = input.checked; }));
            document.getElementById('link').addEventListener('click', e => { window.followed = true; e.preventDefault(); });
            </script>
            """, base: URL(string: "https://example.test/terms")!)
        let fields = await web.extractFields()
        let terms = try XCTUnwrap(fields.first { $0.kind == .checkbox })
        XCTAssertTrue(terms.spec.label.contains("I agree"), terms.spec.label)
        let ticked = await web.fill(terms, "Yes")
        XCTAssertTrue(ticked)
        try await web.sleep(0.2)
        let accepted = try await web.js("return window.accepted", world: .page) as? Bool
        let followed = try await web.js("return window.followed", world: .page) as? Bool
        XCTAssertEqual(accepted, true)
        XCTAssertEqual(followed, false)
    }

    /// Adobe puts its consent statements in one fieldset (legend "usConsent"): each is its own checkbox, so the
    /// required ones get ticked and the text-message one doesn't. A real "pick any" group stays one question.
    func testSeparateStatementsInOneBoxAreSeparateCheckboxes() async throws {
        try await web.loadTestHTML("""
            <form>
            <fieldset id="usConsentObject"><legend role="heading">usConsent</legend>
              <div class="field-boolean"><label><input type="checkbox" id="mail" required aria-required="true"><span>*</span><span>The company may keep me informed with personalized emails about employment opportunities.</span></label></div>
              <div class="field-boolean"><label><input type="checkbox" id="privacy" required aria-required="true"><span>*</span><span>I understand that the information I provide will be used in accordance with the <a href="https://example.com/privacy">Applicant Privacy Policy</a>.</span></label></div>
              <div class="field-boolean"><label><input type="checkbox" id="sms" aria-required="false"><span>Yes, I would like to receive communications via SMS.</span></label></div>
              <div class="field-boolean"><label><input type="checkbox" id="certify" required aria-required="true"><span>*</span><span>I hereby certify that the provided information is true and accurate.</span></label></div>
            </fieldset>
            <fieldset><legend>Which languages do you speak?</legend>
              <label><input type="checkbox" name="langs" value="en"> English</label><label><input type="checkbox" name="langs" value="es"> Spanish</label></fieldset>
            </form>
            """, base: URL(string: "https://example.test/consent")!)
        let fields = await web.extractFields()
        XCTAssertEqual(fields.filter { $0.kind == .checkbox }.count, 4, fields.map(\.spec.label).joined(separator: " | "))
        XCTAssertEqual(fields.filter { $0.kind == .checkboxGroup }.map(\.spec.label), ["Which languages do you speak?"])
        let home = try TestHome()
        let answerer = Answerer(profile: Fixture.profile, db: home.db, ai: nil)
        let res = await answerer.resolve(fields.filter { $0.kind == .checkbox }.map(\.spec), job: Fixture.job)
        for f in fields where f.kind == .checkbox {
            let ok = await web.fill(f, res.answers[f.spec.id] ?? "")
            XCTAssertTrue(ok, f.spec.label)
        }
        let states = try await web.js("return ['mail', 'privacy', 'sms', 'certify'].map(id => document.getElementById(id).checked)", world: .page) as? [Bool]
        XCTAssertEqual(states, [true, true, false, true], "required statements ticked; the optional text messages declined")
    }

    /// The way from a careers page into its application, as different sites word it.
    func testFindsTheWayIntoTheApplication() async throws {
        func entry() async throws -> [String: Any]? { try await web.js(Scripts.tagEntryButton, ["anyButton": true]) as? [String: Any] }
        let workday = "https://bank.wd5.myworkdayjobs.com/External/job/San-Antonio/Software-Engineer-II_R261302/apply"
        // Citi: words for screen readers in the button.
        try await web.loadTestHTML("""
            <main><h1>Junior Application Developer</h1><a class="button job-apply" href="\(workday)" target="_blank">Apply <span class="wai">(opens in new window)</span></a></main>
            """, base: URL(string: "https://jobs.citi.example/job/1")!)
        var r = try await entry()
        XCTAssertEqual(r?["name"] as? String, "Apply")
        XCTAssertEqual(r?["href"] as? String, workday)
        // Frost, as the cloud browser saw it: the application link doesn't say Apply.
        try await web.loadTestHTML("""
            <main><h1>Software Engineer II</h1><a href="\(workday)">Add to cart</a><p>About the job.</p><a href="\(workday)?src=2">Add to cart</a></main>
            """, base: URL(string: "https://careers.bank.example/us/en/job/R261302")!)
        r = try await entry()
        XCTAssertEqual(r?["href"] as? String, workday)
        // A list of other jobs on Workday isn't this job's application.
        try await web.loadTestHTML("""
            <main><h1>Software Engineer II</h1><p>Similar jobs</p>
            <a href="https://bank.wd5.myworkdayjobs.com/External/job/X/Analyst_R1">Analyst</a><a href="https://bank.wd5.myworkdayjobs.com/External/job/X/Teller_R2">Teller</a></main>
            """, base: URL(string: "https://careers.bank.example/us/en/job/R261303")!)
        r = try await entry()
        XCTAssertNil(r)
        // Microsoft: only ways to sign in, and "Create an account" (a "Sign up" in the header is for job alerts).
        try await web.loadTestHTML("""
            <header><a href="#alerts">Sign up</a></header>
            <main><h2>Sign in</h2><button>Sign in using Microsoft</button><button>Sign in using Google</button><p>First time here?</p><button>Create an account</button></main>
            """, base: URL(string: "https://apply.careers.example/careers/apply?pid=1")!)
        r = try await entry()
        XCTAssertEqual(r?["name"] as? String, "Create an account")
    }

    /// LinkedIn's public pages (shown once it ends the session) are told apart from the signed-in ones.
    func testSignedOutLinkedInPages() async throws {
        let search = URL(string: "https://www.linkedin.com/jobs/search/")!
        try await web.loadTestHTML(#"""
            <html><body><header><a class="nav__button-secondary" href="https://www.linkedin.com/login">Sign in</a></header>
            <main><a data-tracking-control-name="public_jobs_jserp-result_search-card" href="/jobs/view/ios-engineer-4100000001">iOS Engineer</a></main></body></html>
            """#, base: search)
        let signedOut = await web.bool(Scripts.linkedInSignedOutPage)
        XCTAssertTrue(signedOut)
        try await web.loadTestHTML(#"""
            <html><body><header id="global-nav"><a href="/feed/">Home</a></header>
            <main><ul><li data-occludable-job-id="4100000001"></li></ul></main></body></html>
            """#, base: search)
        let signedIn = await web.bool(Scripts.linkedInSignedOutPage)
        XCTAssertFalse(signedIn)
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

@MainActor
extension FormTests {
    /// Paylocity's lists show their choice beside an empty text box marked required: "--" there is no choice, and the
    /// browser's "Fill out this field" for the box of a list showing "TX" is no error.
    func testListShowingItsChoiceBesideAnEmptyBox() async throws {
        try await web.loadTestHTML("""
            <form>
              <label for="st"><span>State</span><div aria-haspopup="listbox" aria-owns="l1"><div class="input-select-input-single-value">TX</div>
                <input id="st" aria-autocomplete="list" required value=""></div></label>
              <label for="sms"><span>Do you give us permission to text you?</span><div aria-haspopup="listbox" aria-owns="l2">
                <div class="input-select-input-single-value">--</div><input id="sms" aria-autocomplete="list" required value=""></div></label>
            </form>
            """, base: URL(string: "https://recruiting.paylocity.com/Recruiting/Jobs/Apply/1")!)
        let fields = await web.extractFields(readOptions: false)
        XCTAssertEqual(fields.map(\.spec.currentValue), ["TX", ""], "\(fields.map(\.spec.label))")
        let errors = await web.collectErrors()
        XCTAssertEqual(errors.count, 1, "\(errors)")
        XCTAssertEqual(errors[fields[1].id] != nil, true, "\(errors)")
    }

    /// A box that becomes the browser's date picker once it has the focus takes 2026-12-13, not 12/13/2026.
    func testDateBoxThatTakesOnlyTheISOForm() async throws {
        try await web.loadTestHTML("""
            <form><label for="d">Available to Start</label>
              <input id="d" type="text" placeholder="MM/DD/YYYY" onfocus="this.type='date'" onblur="this.type='text'"></form>
            """, base: URL(string: "https://recruiting.paylocity.com/Recruiting/Jobs/Apply/1")!)
        let found = await web.extractFields()
        let field = try XCTUnwrap(found.first)
        let filled = await web.fill(field, "12/13/2026")
        XCTAssertTrue(filled)
        // (The cloud browser's page has no focus to turn the box into a date picker; there 12/13/2026 stays as typed.)
        let value = try await web.js("return document.getElementById('d').value") as? String
        XCTAssertTrue(["2026-12-13", "12/13/2026"].contains(value ?? ""), value ?? "nil")
    }

    /// Rippling: a list named only "Select" with its question in a paragraph further up, and a file box inside a label
    /// that names itself after "Résumé" (its own words are "Drop or select").
    func testQuestionBesideAListNamedSelect() async throws {
        try await web.loadTestHTML("""
            <form onsubmit="return false"><h1>Application: Developer</h1>
              <div data-testid="field"><div><span id="rl">Résumé</span><span>*</span></div>
                <div><div id="st">Total 0 file selected</div>
                  <label aria-labelledby="st rl"><input type="file" accept=".pdf"><button type="button"><span>Drop or select (.pdf)</span></button></label></div></div>
              <div><div><div><p>Are you legally authorized to work in the United States?</p></div></div>
                <div data-testid="field"><div><div data-testid="q1"><div><div class="select-controller"><div>
                  <div id="q1" role="combobox" aria-haspopup="listbox" aria-expanded="false" aria-label="Select" aria-required="true" tabindex="0"><p>Select</p></div>
                </div></div></div></div></div></div></div>
              <div><div><div><p>To be considered, please pick the opposite of Yes.</p></div></div>
                <div data-testid="field"><div><div data-testid="q2"><div><div class="select-controller"><div>
                  <div id="q2" role="combobox" aria-haspopup="listbox" aria-expanded="false" aria-label="Select" aria-required="true" tabindex="0"><p>Select</p></div>
                </div></div></div></div></div></div></div>
              <button type="submit" aria-disabled="true">Apply</button>
            </form>
            """, base: URL(string: "https://ats.rippling.com/acme/jobs/1/apply")!)
        let fields = await web.extractFields(readOptions: false)
        XCTAssertEqual(fields.map(\.spec.label), ["Résumé", "Are you legally authorized to work in the United States?",
                                                  "To be considered, please pick the opposite of Yes."])
        XCTAssertEqual(fields.first?.fileKind, "resume")
    }
}

