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

    func context(_ model: FakeModel, practice: Bool, verifier: EmailVerifier? = nil, secrets: Secrets = Secrets(),
                 profile: Profile = Fixture.profile, helper: AIService? = nil) -> ApplyContext {
        let ai = AIService(model: model)
        var settings = Store(paths: home.paths).loadSettings()
        settings.practiceMode = practice
        return ApplyContext(jobID: "4242", job: Fixture.job, settings: settings, paths: home.paths, profile: profile, db: home.db,
                            answerer: Answerer(profile: profile, db: home.db, ai: ai), ai: ai,
                            verifier: verifier ?? EmailVerifier(secrets: Secrets(), ai: nil), secrets: secrets, practice: practice,
                            helper: helper) { [weak self] in
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

    /// LinkedIn shown in Spanish (the member's display language): the same dialog, Spanish buttons.
    func testEasyApplyInSpanish() async throws {
        try await openEasyApply(query: "?lang=es")
        var result = try await EasyApplyHandler(web: web, ctx: context(Self.easyModel(), practice: true)).apply()
        XCTAssertEqual(result.status, .practiceComplete, result.notes)
        let discarded = try await page("window.__discarded") as? Bool
        XCTAssertEqual(discarded, true)

        try await openEasyApply(query: "?lang=es")
        result = try await EasyApplyHandler(web: web, ctx: context(Self.easyModel(), practice: false)).apply()
        XCTAssertEqual(result.status, .applied, result.notes)
        let submitted = try await page("window.__submitted") as? Bool
        XCTAssertEqual(submitted, true)
    }

    /// LinkedIn's newer job page draws the window inside an open shadow root, without dialog markup.
    func testEasyApplyInsideShadowRoot() async throws {
        try await openEasyApply(query: "?shadow=1")
        var result = try await EasyApplyHandler(web: web, ctx: context(Self.easyModel(), practice: true)).apply()
        XCTAssertEqual(result.status, .practiceComplete, result.notes)
        let discarded = try await page("window.__discarded") as? Bool
        XCTAssertEqual(discarded, true)

        try await openEasyApply(query: "?shadow=1")
        result = try await EasyApplyHandler(web: web, ctx: context(Self.easyModel(), practice: false)).apply()
        XCTAssertEqual(result.status, .applied, result.notes)
        let submitted = try await page("window.__submitted") as? Bool
        let follow = try await page("window.__followAtSubmit") as? Bool
        XCTAssertEqual(submitted, true)
        XCTAssertEqual(follow, false)
    }

    /// A job that applies on the company's site, with suggested Easy Apply jobs below it: not taken for Easy Apply.
    func testSuggestedJobsArentTheJobsButton() async throws {
        try await web.loadTestHTML(#"""
            <html><body><main><h1>Software Engineer</h1><div id="job-details">We build things with Swift and Go, and we need help with all of it.</div>
            <a href="https://careers.example.com/jobs/1" aria-label="Apply on company website">Apply</a>
            <section><h2>More jobs</h2>
            <a href="https://www.linkedin.com/jobs/view/4100000009/"><p>Java Developer</p><p>Synechron</p><p>4 days ago · Easy Apply</p></a>
            <a href="https://www.linkedin.com/jobs/search-results/?f_AL=true">Easy Apply</a></section></main></body></html>
            """#, base: URL(string: "https://www.linkedin.com/jobs/view/4100000001/")!)
        let details = try await web.readJobDetails()
        XCTAssertEqual(details.kind, .external)
    }

    func testEasyApplySubmitsAndFixesValidation() async throws {
        try await openEasyApply()
        let model = Self.easyModel()
        // A start the app can't write as a date, so the form turns it away and the AI gets the form's message.
        var profile = Fixture.profile
        profile.preferences.earliestStartDate = "Flexible"
        let result = try await EasyApplyHandler(web: web, ctx: context(model, practice: false, profile: profile)).apply()
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
        let verifier = EmailVerifier(secrets: secrets, ai: nil, pollInterval: 0.05, openSession: { _ in box })
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

    /// Conduent: State / Province has nothing to choose until the Country is in; it's answered once it has.
    func testAListWhoseChoicesComeAfterTheCountry() async throws {
        try await web.loadTestHTML("""
            <form onsubmit="return false"><h1>Personal information</h1>
              <label for="fn">First Name*</label><input id="fn" required>
              <label for="em">Email*</label><input id="em" type="email" required>
              <label for="co">Country*</label><select id="co" required><option value="">Select</option><option>Canada</option><option>United States</option></select>
              <label for="st">State / Province*</label><select id="st" required><option value="">Select</option></select>
              <button type="submit">Submit</button>
            </form>
            <script>
              document.getElementById('co').addEventListener('change', e => {
                const st = document.getElementById('st');
                setTimeout(() => {
                  st.innerHTML = '<option value="">Select</option>' + (e.target.value === 'United States'
                    ? '<option>Tennessee</option><option>Texas</option><option>Utah</option>' : '<option>Ontario</option>');
                }, 400);
              });
            </script>
            """, base: URL(string: "https://careers.example.org/us/en/apply?step=1")!)
        let result = try await GenericHandler(web: web, ctx: context(FakeModel(), practice: true)).apply()
        XCTAssertEqual(result.status, .practiceComplete, result.notes)
        let state = try await web.js("return document.getElementById('st').value") as? String
        XCTAssertEqual(state, "Texas")
    }

    // MARK: getting to the form on company sites

    func reach() async throws -> ATSType? {
        switch try await SiteRouter.reachApplication(web, step: { [weak self] in self?.steps.append($0) }) {
        case .ready(let ats): return ats
        case .stop(let note):
            XCTFail("Stopped: \(note)")
            return nil
        }
    }

    /// Infosys: a cookie banner over the page, "Apply" for first-time applicants, a privacy notice with "Proceed",
    /// then the form (a chat box and a "Save job" box aren't the form).
    func testReachesTheFormPastBannerApplyAndPrivacyNotice() async throws {
        try await open("careers_entry.html")
        let before = await web.fieldCount()
        XCTAssertEqual(before, 0, "search boxes, the chat box and Save job aren't an application")
        let ats = try await reach()
        XCTAssertEqual(ats, .generic)
        let consent = try await page("window.__consent") as? String
        XCTAssertEqual(consent, "rejected", "declines optional cookies")
        let formShown = await web.isVisible("#firstname")
        XCTAssertTrue(formShown, steps.joined(separator: " | "))
        let result = try await GenericHandler(web: web, ctx: context(FakeModel(), practice: true)).apply()
        XCTAssertEqual(result.status, .practiceComplete, result.notes)
        let first = try await page("document.getElementById('firstname').value") as? String
        XCTAssertEqual(first, "Jane")
        let sent = try await page("window.__sent === true") as? Bool
        XCTAssertEqual(sent, false)
    }

    /// U.S. Bank: "Apply now" links open the application (on Workday) in a new tab; the app opens it in its own tab.
    func testFollowsAnApplyLinkThatOpensANewTab() async throws {
        try await open("careers_link.html")
        let pressed = await web.dismissBanners()
        XCTAssertEqual(pressed, ["Decline optional Cookies"])
        let consent = try await page("window.__consent") as? String
        XCTAssertEqual(consent, "declined")
        let count = await web.fieldCount()
        XCTAssertEqual(count, 0)
        _ = try await reach()
        XCTAssertEqual(web.url?.lastPathComponent, "generic_form.html", web.url?.absoluteString ?? "")
    }

    /// Cookie banners without a "Reject" button: Pinterest's "Essential Only" is the decline; Fivetran's (OneTrust)
    /// offers only "Accept All Cookies" and "Personalize My Choices", whose panel's optional switches are turned off
    /// and saved. A "Cookie Settings" link in the footer is left alone.
    func testCookieBannersDeclinedWithoutARejectButton() async throws {
        try await web.loadTestHTML("""
            <body><main><h1>Careers</h1></main>
            <div id="bar" class="js-cookie-bar" style="position:fixed;bottom:0">We use cookies to improve your experience.
              <button onclick="window.__consent='all'; this.parentNode.remove()">Accept All</button>
              <button onclick="window.__consent='essential'; this.parentNode.remove()">Essential Only</button></div>
            </body>
            """, base: URL(string: "https://careers.example.test/")!)
        let pressed = await web.dismissBanners()
        XCTAssertEqual(pressed, ["Essential Only"])
        let consent = try await page("window.__consent") as? String
        XCTAssertEqual(consent, "essential")

        try await web.loadTestHTML("""
            <body><main><h1>Careers</h1></main>
            <footer class="cookie-links"><a href="#" onclick="window.__footer = true">Cookie Settings</a></footer>
            <div id="onetrust-banner-sdk" style="position:fixed;bottom:0">We use cookies and similar tracking technology.
              <button onclick="window.__consent='all'; this.parentNode.remove()">Accept All Cookies</button>
              <button id="onetrust-pc-btn-handler" onclick="document.getElementById('onetrust-pc-sdk').style.display='block'; this.parentNode.remove()">Personalize My Choices</button></div>
            <div id="onetrust-pc-sdk" style="display:none;position:fixed;top:0">Privacy preference center: cookies we use.
              <label><input type="checkbox" checked disabled> Strictly necessary</label>
              <label><input type="checkbox" id="perf" checked> Performance cookies</label>
              <label><input type="checkbox" id="ads" checked> Targeting cookies</label>
              <button onclick="window.__consent = 'saved:' + document.getElementById('perf').checked + ',' + document.getElementById('ads').checked; this.parentNode.remove()">Confirm My Choices</button>
              <button onclick="window.__consent='all'; this.parentNode.remove()">Allow All</button></div>
            </body>
            """, base: URL(string: "https://careers.example.test/")!)
        let pressed2 = await web.dismissBanners()
        XCTAssertEqual(pressed2, ["Personalize My Choices", "Confirm My Choices"])
        let consent2 = try await page("window.__consent") as? String
        XCTAssertEqual(consent2, "saved:false,false")
        let footer = try await page("window.__footer === true") as? Bool
        XCTAssertEqual(footer, false)

        // Oracle's at Uber: "Got It", "Opt Out" and "Manage Preferences".
        try await web.loadTestHTML("""
            <body><main><h1>Careers</h1></main>
            <div class="cookie-consent" style="position:fixed;bottom:0">This site uses cookies.
              <button onclick="window.__consent='all'; this.parentNode.remove()">Got It</button>
              <button onclick="window.__consent='out'; this.parentNode.remove()">Opt Out</button>
              <button>Manage Preferences</button></div>
            </body>
            """, base: URL(string: "https://careers.example.test/")!)
        let pressed3 = await web.dismissBanners()
        XCTAssertEqual(pressed3, ["Opt Out"])

        // Dassault Systèmes': "Continue with only necessary cookies" beside "Accept All" and "Manage my preferences"
        // (the run opened the preferences on every page and never closed them).
        try await web.loadTestHTML("""
            <body><main><h1>Careers</h1></main>
            <div id="footer_tc_privacy" class="tc-privacy-banner" style="position:fixed;bottom:0">We use cookies to personalize your experience.
              <button onclick="window.__consent='necessary'; this.parentNode.remove()">Continue with only necessary cookies</button>
              <button onclick="window.__consent='all'; this.parentNode.remove()">Accept All</button>
              <button onclick="window.__consent='manage'">Manage my preferences</button></div>
            </body>
            """, base: URL(string: "https://careers.example.test/")!)
        let pressed4 = await web.dismissBanners()
        XCTAssertEqual(pressed4, ["Continue with only necessary cookies"])
        let consent4 = try await page("window.__consent") as? String
        XCTAssertEqual(consent4, "necessary")
    }

    /// iCIMS: the site's search boxes on top and the application in a frame.
    func testOpensAFormDrawnInAFrame() async throws {
        try await open("careers_frame.html")
        _ = try await reach()
        XCTAssertEqual(web.url?.lastPathComponent, "careers_frame_inner.html", web.url?.absoluteString ?? "")
        let result = try await GenericHandler(web: web, ctx: context(FakeModel(), practice: true)).apply()
        XCTAssertEqual(result.status, .practiceComplete, result.notes)
        let text = await web.text()
        XCTAssertTrue(text.contains("Submit Application"), "went past “I Acknowledge the Privacy Notice”: \(text)")
    }

    /// iCIMS: the job and its "Apply for this job online" link sit in a frame from the same site; the page around it
    /// has no Apply button of its own.
    func testFollowsAnApplyLinkInsideAFrame() async throws {
        try await open("careers_job_frame.html")
        _ = try await reach()
        XCTAssertEqual(web.url?.lastPathComponent, "careers_frame_inner.html", web.url?.absoluteString ?? "")
    }

    /// BrassRing: the job page's way in is a button named "Submit" (#applyFromDetailBtn), next to "Save"; it opens a
    /// sign-in box whose way in for new people is "Don't have an account yet?".
    func testPressesAnApplyButtonKnownByItsId() async throws {
        try await web.loadTestHTML("""
            <h1>Java Software Engineer - San Diego, CA</h1><h2>Job Description</h2>
            <p>If you have the required skill set, please click the submit button and follow the next steps.</p>
            <button id="saveJobBtn">Save</button>
            <button class="primaryButton" id="applyFromDetailBtn" ng-click="postToNextPageFromDetails($event,this,'apply')">Submit</button>
            <script>
            document.getElementById('saveJobBtn').onclick = () => { window.__saved = true; };
            document.getElementById('applyFromDetailBtn').onclick = () => {
              document.body.innerHTML = '<h1>Sign In</h1><form onsubmit="return false"><label for="u">*Username</label><input id="u">' +
                '<label for="p">*Password</label><input id="p" type="password"><button id="btnLogin">Sign in</button></form>' +
                '<a href="#" id="new">Don\\'t have an account yet?</a>';
            };
            </script>
            """, base: URL(string: "https://sjobs.example.test/TGnewUI/Search/home/HomeWithPreLoad?PageType=JobDetails&jobId=1")!)
        _ = try await reach()
        XCTAssertTrue(steps.contains("Pressed “Submit”"), steps.joined(separator: " | "))
        let saved = try await page("window.__saved === true") as? Bool
        XCTAssertEqual(saved, false)
        let way = await web.findButton(newAccountPattern)
        XCTAssertEqual(way, "Don't have an account yet?")
    }

    /// Infosys: after the resume goes up, a popup offers to import what it read from it, and keeps the keyboard to
    /// itself. The app closes it (it fills the form from the profile) and picks the school from the list searched by
    /// typing on the next page.
    func testClosesTheResumeImportPopup() async throws {
        try await open("careers_resume_popup.html")
        let result = try await GenericHandler(web: web, ctx: context(FakeModel(), practice: true)).apply()
        XCTAssertEqual(result.status, .practiceComplete, "\(result.notes) | \(steps.joined(separator: " | "))")
        let school = try await page("window.__school || ''") as? String
        XCTAssertEqual(school, "University of Texas at Austin")
        let imported = try await page("window.__imported === true") as? Bool
        XCTAssertEqual(imported, false)
        let shown = try await page("document.getElementById('modal').classList.contains('show')") as? Bool
        XCTAssertEqual(shown, false)
    }

    /// Oracle's "Confirm your identity" (Uber, 2026): six one-digit boxes that take digits typed on the keyboard and move
    /// on by themselves; a digit set any other way is put back. The code is typed, so every box keeps its digit.
    func testTypesASplitCodeLikeAKeyboard() async throws {
        try await web.loadTestHTML("""
            <h1>Confirm your identity</h1><p>The verification code was sent to this email address.</p>
            <form onsubmit="return false"><label>Verification Code</label>
              <div>\((0..<6).map { #"<input class="pin" type="text" inputmode="numeric" maxlength="1" aria-label="Digit \#($0 + 1)">"# }.joined())</div>
              <button type="button" id="verify">Verify</button></form>
            <script>
            const model = ['', '', '', '', '', ''], boxes = [...document.querySelectorAll('.pin')];
            boxes.forEach((b, i) => {
              b.addEventListener('keydown', e => { if (/^\\d$/.test(e.key)) { e.preventDefault(); model[i] = e.key; b.value = e.key; if (boxes[i + 1]) boxes[i + 1].focus(); } });
              b.addEventListener('input', () => { b.value = model[i]; });
              b.addEventListener('blur', () => { b.value = model[i]; });
            });
            document.getElementById('verify').onclick = () => {
              window.__code = model.join('');
              if (window.__code.length === 6) document.body.innerHTML = '<form onsubmit="return false"><label for="why">Why us?</label>' +
                '<textarea id="why"></textarea><button type="submit">Submit application</button></form>';
            };
            </script>
            """, base: URL(string: "https://careers.initech.example/apply/email")!)
        var secrets = Secrets()
        (secrets.imapUser, secrets.imapPassword, secrets.imapHost) = ("jane.doe@example.com", "abcdabcdabcdabcd", "imap.example.com")
        let box = FakeMailbox([])
        let mail = Self.plainMail(from: "Initech Careers <no-reply@initech.example>", subject: "Confirm your identity",
                                  "Your verification code is 482913.\n")
        box.onRefresh = { [unowned box] in if box.messages.isEmpty { box.messages.append((1, mail, false)) } }
        let verifier = EmailVerifier(secrets: secrets, ai: nil, pollInterval: 0.05, openSession: { _ in box })
        let result = try await GenericHandler(web: web, ctx: context(FakeModel(), practice: true, verifier: verifier, secrets: secrets)).apply()
        XCTAssertEqual(result.status, .practiceComplete, "\(result.notes) | \(steps.joined(separator: " | "))")
        let code = try await page("window.__code || ''") as? String
        XCTAssertEqual(code, "482913")
    }

    /// Avature: a sign-in box beside a resume upload for first-timers; the sign-up page (password twice, consent,
    /// talent community, text messages) is the application's first page; an emailed code; then the last page.
    func testSignsUpAndEntersTheEmailedCode() async throws {
        try await open("careers_account.html")
        var secrets = Secrets()
        (secrets.imapUser, secrets.imapPassword, secrets.imapHost) = ("jane.doe@example.com", "abcdabcdabcdabcd", "imap.example.com")
        secrets.portalPassword = "Portal-Pass-2026!"
        let box = FakeMailbox([])
        let code = """
            From: Initech Careers <no-reply@initech.example>
            To: jane.doe@example.com
            Subject: Your Initech verification code
            Date: \(Self.rfc2822(Date()))
            Content-Type: text/plain; charset="utf-8"
            MIME-Version: 1.0

            Your verification code is 482913. It expires in 10 minutes.
            """.replacingOccurrences(of: "\n", with: "\r\n")
        box.onRefresh = { [unowned box] in
            if box.messages.isEmpty { box.messages.append((1, Data(code.utf8), false)) }
        }
        let verifier = EmailVerifier(secrets: secrets, ai: nil, pollInterval: 0.05, openSession: { _ in box })
        let result = try await GenericHandler(web: web, ctx: context(FakeModel(), practice: true, verifier: verifier, secrets: secrets)).apply()
        XCTAssertEqual(result.status, .practiceComplete, "\(result.notes) | \(steps.joined(separator: " | "))")
        let reg = try await page("JSON.parse(sessionStorage.getItem('reg') || 'null')") as? [String: Any]
        XCTAssertEqual(reg?["pw"] as? String, "Portal-Pass-2026!")
        XCTAssertEqual(reg?["confirm"] as? String, "Portal-Pass-2026!")
        XCTAssertEqual(reg?["email"] as? String, "jane.doe@example.com")
        XCTAssertEqual(reg?["year"] as? String, "2019", "Education › End date year from the profile")
        XCTAssertEqual(reg?["community"] as? String, "No")
        XCTAssertEqual(reg?["texts"] as? String, "No")
        XCTAssertEqual(reg?["consent"] as? Bool, true)
        let tried = try await page("window.__loginTried === true") as? Bool
        XCTAssertEqual(tried, false, "no account yet, so it doesn't try to sign in")
        XCTAssertTrue(steps.contains("Entered the code from your email"), steps.joined(separator: " | "))
        XCTAssertTrue(home.db.listPending().isEmpty, home.db.listPending().map(\.question).joined(separator: "; "))
    }

    /// Workday's Create Account button is hidden under a "click_filter" placed just before it: that's what is pressed
    /// (pressing the button itself does nothing), the honeypot stays empty, and practice stops at Submit.
    func testWorkdayCreatesTheAccountThroughItsClickFilter() async throws {
        try await open("workday.html")
        var secrets = Secrets()
        secrets.portalPassword = "Portal-Pass-2026!"
        let result = try await WorkdayHandler(web: web, ctx: context(FakeModel(), practice: true, secrets: secrets)).apply()
        XCTAssertEqual(result.status, .practiceComplete, "\(result.notes) | \(steps.joined(separator: " | "))")
        let created = try await page("window.__created") as? Bool
        let bee = try await page("window.__bee") as? String
        XCTAssertEqual(created, true)
        XCTAssertEqual(bee, "", "the hidden honeypot field is left alone")
        let text = await web.text()
        XCTAssertFalse(text.contains("Application Submitted"), text)
    }

    /// "My Experience" as Workday leaves it after reading the resume (McKesson, Blue Origin): the current job gets
    /// "I currently work here", the job with no From date gets the profile's, the job the profile doesn't have is left
    /// alone, the school is searched and picked from the list, and the resume is attached.
    func testWorkdayMyExperienceFromTheProfile() async throws {
        try await open("workday.html", query: "?experience=1")
        let result = try await WorkdayHandler(web: web, ctx: context(FakeModel(), practice: true)).apply()
        XCTAssertEqual(result.status, .practiceComplete, "\(result.notes) | \(steps.joined(separator: " | "))")
        let got = try await page("JSON.stringify(window.__experience || null)") as? String ?? ""
        let seen = (try? JSONSerialization.jsonObject(with: Data(got.utf8))) as? [String: Any] ?? [:]
        XCTAssertEqual(seen["current"] as? Bool, true, got)
        XCTAssertEqual(seen["from2"] as? String, "06/2019", got)
        XCTAssertEqual(seen["hooli"] as? Bool, false, "a job the profile doesn't have is left alone")
        XCTAssertEqual(seen["school"] as? String, "The University of Texas at Austin", got)
        XCTAssertNotNil(seen["file"] as? String, got)
    }

    /// A box Workday says is still empty (a school the profile doesn't have): the app stops after a few tries, naming
    /// it, instead of pressing Next until the page limit.
    func testWorkdayStopsWhenABoxStaysEmpty() async throws {
        try await open("workday.html", query: "?experience=1")
        var p = Fixture.profile
        p.education = []
        let result = try await WorkdayHandler(web: web, ctx: context(FakeModel(), practice: true, profile: p)).apply()
        XCTAssertEqual(result.status, .failedForm, result.notes)
        XCTAssertTrue(result.notes.contains("School or University"), result.notes)
        let presses = try await page("window.__presses") as? Int ?? 0
        XCTAssertLessThanOrEqual(presses, 4)
    }

    /// A careers page that embeds Ashby's whole job board (Tillster): the job is found on it by title, in its city.
    func testAshbyBoardPicksTheJob() {
        let titles = ["Operations Account Manager", "Data Analyst", "Data Analyst", "Senior Data Analyst"]
        let details = ["Account Management • Florida", "Data Science • San Diego Office • Hybrid", "Data Science • Atlanta • Remote", "Data Science • Atlanta"]
        XCTAssertEqual(AshbyHandler.sameTitle("Data Analyst", titles, details: details, location: "Atlanta, GA"), 2)
        XCTAssertEqual(AshbyHandler.sameTitle("Data Analyst", titles, details: details, location: "Remote"), 2)
        XCTAssertEqual(AshbyHandler.sameTitle("Data Analyst", titles, details: details, location: "Chicago, IL"), 1, "no city fits: the first")
        XCTAssertEqual(AshbyHandler.sameTitle("Operations Account Manager", titles), 0)
        XCTAssertNil(AshbyHandler.sameTitle("Backend Engineer", titles))
        XCTAssertEqual(AshbyHandler.sameTitle("Senior Backend Engineer", ["Senior Backend Engineer - Payments", "Staff Engineer"]), 0)
    }

    /// "My Information" with Workday's Country, phone code and number from the resume (Dexcom, Caterpillar): set from
    /// the profile, the number without its country code.
    func testWorkdayCountryAndPhoneFromTheProfile() async throws {
        try await open("workday.html", query: "?info=1")
        let result = try await WorkdayHandler(web: web, ctx: context(FakeModel(), practice: true)).apply()
        XCTAssertEqual(result.status, .practiceComplete, "\(result.notes) | \(steps.joined(separator: " | "))")
        let got = try await page("JSON.stringify(window.__info || null)") as? String ?? ""
        XCTAssertTrue(got.contains("United States of America (+1)") && got.contains("5551234567"), got)
        XCTAssertTrue(got.contains(#""country":"United States of America""#), got)
        XCTAssertEqual(WorkdayHandler.nationalNumber("+1 (512) 555-0142", code: "1"), "5125550142")
        XCTAssertEqual(WorkdayHandler.nationalNumber("512-555-0142", code: "1"), "5125550142")
        XCTAssertEqual(WorkdayHandler.nationalNumber("+51 987 654 321", code: "51"), "987654321")
    }

    func testClearanceJobsSignUpIsLeftToThePerson() {
        XCTAssertNotNil(SiteRouter.sworeBoard(URL(string: "https://www.clearancejobs.com/registration")))
        XCTAssertNil(SiteRouter.sworeBoard(URL(string: "https://jobs.example.com/apply")))
    }

    func testWorkdayDatesAndNames() {
        XCTAssertEqual(WorkdayHandler.monthYear("2022")?.month, "01")
        XCTAssertEqual(WorkdayHandler.monthYear("2022")?.year, "2022")
        XCTAssertEqual(WorkdayHandler.monthYear("Sep 2021")?.month, "09")
        XCTAssertEqual(WorkdayHandler.monthYear("2019-06")?.month, "06")
        XCTAssertEqual(WorkdayHandler.monthYear("6/2019")?.month, "06")
        XCTAssertNil(WorkdayHandler.monthYear("Present"))
        let roles = [Role(company: "Globex Corporation (GC) – Pacific", title: "Software Engineer (Intern)", startDate: "2022")]
        XCTAssertNotNil(WorkdayHandler.matchRole(roles, company: "Globex Corporation (GC) – Pacific", title: "Software Engineer (Intern) Remote", fromYear: "2022"))
        XCTAssertNil(WorkdayHandler.matchRole(roles, company: "Globex Corporation (GC) – Pacific", title: "Hooli | Software Engineer", fromYear: "2023"),
                     "same company, another start year: another job")
        XCTAssertNil(WorkdayHandler.matchRole(roles, company: "Nevada State University", title: "Software Engineer (Intern)", fromYear: ""))
        let schools = [Education(school: "Nevada State University", degree: "Master’s of Engineering in Computer Science", fieldOfStudy: "Computer Science"),
                       Education(school: "St. Joseph’s University of El Paso", degree: "Bachelor of Arts in Economics", fieldOfStudy: "Economics")]
        XCTAssertEqual(WorkdayHandler.matchSchool(schools, degree: "Bachelors (ex. Bachelors of Arts or Science)", study: "Economics")?.school,
                       "St. Joseph’s University of El Paso")
        XCTAssertEqual(WorkdayHandler.matchSchool(schools, degree: "Master of Engineering (MEng)", study: "")?.school, "Nevada State University")
        XCTAssertEqual(WorkdayHandler.closestSchool("St. Joseph’s University of El Paso",
                                                    ["St. Joseph's College of Maryland", "St. Joseph's University - El Paso, TX", "Saint Joseph's University"]),
                       "St. Joseph's University - El Paso, TX")
        XCTAssertNil(WorkdayHandler.closestSchool("St. Joseph’s University of El Paso", ["St. Joseph's College of Maryland", "Trinity University"]))
    }

    /// Newer Workday sign-in pages offer Apple, Google or "Sign in with email" first (BlackRock): the app takes email,
    /// tries to sign in, then makes the account; never the other companies' sign-in, never the robots' box.
    func testWorkdaySignInWithEmailFirst() async throws {
        try await open("workday.html", query: "?ssofirst=1")
        var secrets = Secrets()
        secrets.portalPassword = "Portal-Pass-2026!"
        let result = try await WorkdayHandler(web: web, ctx: context(FakeModel(), practice: true, secrets: secrets)).apply()
        XCTAssertEqual(result.status, .practiceComplete, "\(result.notes) | \(steps.joined(separator: " | "))")
        let created = try await page("window.__created") as? Bool
        XCTAssertEqual(created, true)
        let sso = try await page("window.__sso || ''") as? String
        XCTAssertEqual(sso, "")
    }

    /// TCS's iBegin opens India's version, which asks for a PAN, a date of birth and an Aadhaar card: a job in the
    /// United States goes to the US version.
    func testCareersSiteForTheJobsCountry() {
        let india = URL(string: "https://ibegin.tcsapps.com/candidate/next/en-IN/register")
        XCTAssertEqual(SiteRouter.countryVersion(india, jobLocation: "Raleigh, NC")?.absoluteString,
                       "https://ibegin.tcsapps.com/candidate/next/en-US/register")
        XCTAssertEqual(SiteRouter.countryVersion(india, jobLocation: "Sunnyvale, CA (Hybrid)")?.path, "/candidate/next/en-US/register")
        XCTAssertEqual(SiteRouter.countryVersion(india, jobLocation: "Austin, Texas, United States")?.path, "/candidate/next/en-US/register")
        XCTAssertEqual(SiteRouter.countryVersion(india, jobLocation: "Toronto, Ontario, Canada")?.path, "/candidate/next/en-CA/register")
        XCTAssertNil(SiteRouter.countryVersion(india, jobLocation: "Bengaluru, Karnataka, India"))
        XCTAssertNil(SiteRouter.countryVersion(india, jobLocation: "Remote"))
        XCTAssertNil(SiteRouter.countryVersion(URL(string: "https://careers.example.com/en-IN/apply"), jobLocation: "Raleigh, NC"))
        XCTAssertNil(SiteRouter.countryVersion(URL(string: "https://ibegin.tcsapps.com/candidate/next/en-US/register"), jobLocation: "Raleigh, NC"))
    }

    /// Workday won't sign in to an account whose email was never confirmed: the app asks for the email again, opens
    /// its link, and signs in (Frost). Needs a page the link can open, so it runs in the cloud browser.
    func testWorkdayConfirmsAnAccountItMadeBefore() async throws {
        try XCTSkipIf(web.cloud == nil, "the activation link is a web address; the cloud tests serve it")
        let token = UUID().uuidString
        let mail = """
            From: Initech Careers <initech@otp.workday.com>
            To: jane.doe@example.com
            Subject: Verify your candidate account
            Date: \(Self.rfc2822(Date()))
            Content-Type: text/html; charset="utf-8"
            MIME-Version: 1.0

            <html><body><a href="https://wd5.myworkday.com/initech"><img src="https://wd5.myworkday.com/logo.png" alt=""></a>
            <p>Click this link to confirm your email address and complete setup for your candidate account</p>
            <p>https://fixtures.test/workday.html?activate=\(token)</p></body></html>
            """.replacingOccurrences(of: "\n", with: "\r\n")
        let box = FakeMailbox([Data(mail.utf8)])
        var secrets = Secrets()
        secrets.portalPassword = "Portal-Pass-2026!"
        secrets.imapHost = "imap.example.test"
        secrets.imapUser = "jane.doe@example.com"
        secrets.imapPassword = "app-password"
        let verifier = EmailVerifier(secrets: secrets, ai: nil, pollInterval: 0.05, openSession: { _ in box })
        try await open("workday.html", query: "?unverified=\(token)")
        let result = try await WorkdayHandler(web: web, ctx: context(FakeModel(), practice: true, verifier: verifier, secrets: secrets)).apply()
        XCTAssertEqual(result.status, .practiceComplete, "\(result.notes) | \(steps.joined(separator: " | "))")
        XCTAssertTrue(steps.contains { $0.contains("send the verification email again") }, steps.joined(separator: " | "))
    }

    /// An email made by hand on Workday, with another password (Salesforce): Create Account comes back to Sign In,
    /// signing in says the password is wrong, so the app resets it to the portal password through Workday's email.
    func testWorkdayResetsThePasswordOfAnAccountMadeByHand() async throws {
        try XCTSkipIf(web.cloud == nil, "the reset link is a web address; the cloud tests serve it")
        let token = UUID().uuidString
        let secrets = Self.mailSecrets
        let box = FakeMailbox([])
        let mail = Self.plainMail(from: "Initech Careers <initech@otp.workday.com>", subject: "Reset your password",
                                  "Click the link below to reset your password. It expires in 24 hours.\n\nhttps://fixtures.test/workday.html?reset=\(token)\n")
        box.onRefresh = { [weak self, unowned box] in
            Task { @MainActor in
                // Only once the app asked for it.
                guard box.messages.isEmpty, let asked = try? await self?.page("window.__resetAsked || ''") as? String, !asked.isEmpty else { return }
                box.messages.append((1, mail, false))
            }
        }
        let verifier = EmailVerifier(secrets: secrets, ai: nil, pollInterval: 0.2, openSession: { _ in box })
        try await open("workday.html", query: "?existing=\(token)")
        let result = try await WorkdayHandler(web: web, ctx: context(FakeModel(), practice: true, verifier: verifier, secrets: secrets)).apply()
        XCTAssertEqual(result.status, .practiceComplete, "\(result.notes) | \(steps.joined(separator: " | "))")
        XCTAssertTrue(steps.contains { $0.contains("resetting its password to your portal password") }, steps.joined(separator: " | "))
        let signIns = try await page("window.__signIns || 0") as? Int
        XCTAssertLessThanOrEqual(signIns ?? 99, 3, "Workday locks an account after five wrong passwords")
        XCTAssertEqual(home.db.accounts().map(\.how), [.reset])
    }

    /// A careers site whose sign-up page says the email already has an account: the app resets that account's
    /// password to the portal password (sign in, "Forgot your password?", the emailed link), then signs in.
    func testResetsThePasswordWhenTheEmailAlreadyHasAnAccount() async throws {
        try XCTSkipIf(web.cloud == nil, "the reset link is a web address; the cloud tests serve it")
        let token = UUID().uuidString
        let secrets = Self.mailSecrets
        let mail = Self.plainMail(from: "Initech Careers <no-reply@initech.example>", subject: "Reset your Initech password",
                                  "We received a request to reset your password.\n\nReset it here: https://fixtures.test/careers_reset.html?step=reset&t=\(token)\n\n"
                                  + "Your reference number is 482913.\n")
        let box = FakeMailbox([])
        box.onRefresh = { [weak self, unowned box] in
            Task { @MainActor in
                guard box.messages.isEmpty, let asked = try? await self?.page("sessionStorage.getItem('resetAsked-\(token)') || ''") as? String,
                      !asked.isEmpty else { return }
                box.messages.append((1, mail, false))
            }
        }
        let verifier = EmailVerifier(secrets: secrets, ai: nil, pollInterval: 0.2, openSession: { _ in box })
        try await open("careers_reset.html", query: "?step=register&t=\(token)")
        let result = try await GenericHandler(web: web, ctx: context(FakeModel(), practice: true, verifier: verifier, secrets: secrets)).apply()
        XCTAssertEqual(result.status, .practiceComplete, "\(result.notes) | \(steps.joined(separator: " | "))")
        XCTAssertTrue(steps.contains { $0.contains("resetting its password to your portal password") }, steps.joined(separator: " | "))
        let asked = try await page("sessionStorage.getItem('resetAsked-\(token)')") as? String
        XCTAssertEqual(asked, Fixture.profile.personal.email)
        let pw = try await page("localStorage.getItem('pw-\(token)')") as? String
        XCTAssertEqual(pw, secrets.portalPassword, "the same password everywhere")
        XCTAssertEqual(home.db.accounts().map(\.how), [.reset])
    }

    /// TCS's US registration end to end: the title the person gave once, the time zone from the address, the skills
    /// as chips; "M.I." left empty.
    func testTCSRegistrationWithListsAndChips() async throws {
        home.db.cachePut(Answerer.hash(field("Title", .combobox, ["Dr.", "Mr.", "Ms."])), question: "Title", fieldType: "combobox",
                         options: ["Dr.", "Mr.", "Ms."], answer: "Mr.", source: "user")
        try await open("tcs_register.html")
        let result = try await GenericHandler(web: web, ctx: context(FakeModel(), practice: true)).apply()
        XCTAssertEqual(result.status, .practiceComplete, "\(result.notes) | \(steps.joined(separator: " | "))")
        let sent = try await page("JSON.parse(sessionStorage.getItem('tcsResult') || 'null')") as? [String: Any]
        XCTAssertEqual(sent?["title"] as? String, "Mr.")
        XCTAssertEqual(sent?["tz"] as? String, "America/Chicago")
        XCTAssertEqual(sent?["skills"] as? [String], ["Python", "AWS", "SQL", "PostgreSQL", "Docker"])
        XCTAssertEqual(sent?["mi"] as? String, "")
    }

    /// LinkedIn's "Job search safety reminder" after Apply (Uber, 2026), not marked as a dialog: "Continue applying"
    /// is pressed and the company's page opens.
    func testLinkedInSafetyReminderBeforeTheCompanySite() async throws {
        try await web.loadTestHTML("""
            <main><h1>Software Engineer II</h1><button data-auto-apply="1" id="apply">Apply</button></main>
            <div id="layer"></div>
            <script>
            document.getElementById('apply').onclick = () => {
              document.getElementById('layer').innerHTML = '<div class="jobs-safety-reminder"><h2>Job search safety reminder</h2>' +
                '<p>Before you apply, review the employer’s official website.</p><button id="go">Continue applying</button></div>';
              document.getElementById('go').onclick = () => { history.pushState({}, '', '/careers/apply/1'); };
            };
            </script>
            """, base: URL(string: "https://www.linkedin.com/jobs/view/4489697877/")!)
        try await web.openExternalApplication(timeout: 4)
        XCTAssertEqual(web.url?.path, "/careers/apply/1")
    }

    /// Amazon's "Get SMS updates" step has no questions, only "Skip & continue": it's still the application.
    func testGoesOnPastAStepWithoutQuestions() async throws {
        try await web.loadTestHTML("""
            <main id="m"><h3>My progress</h3><h2>Get SMS updates on your job applications</h2>
              <p>Your applications will be processed normally even if you don't verify your number.</p>
              <p>Phone number (Unverified) +1 555-0100 <a href="#">Edit</a></p>
              <button type="button" id="sms">Enable SMS updates</button> <button type="button" id="skip">Skip &amp; continue</button></main>
            <script>
            document.getElementById('sms').onclick = () => { window.__sms = true; };
            document.getElementById('skip').onclick = () => {
              document.getElementById('m').innerHTML = '<form onsubmit="return false"><label for="why">Why Amazon?</label><textarea id="why"></textarea>' +
                '<button type="submit">Submit application</button></form>';
            };
            </script>
            """, base: URL(string: "https://account.example.test/en-US/applicant/jobs/1/apply")!)
        let result = try await GenericHandler(web: web, ctx: context(FakeModel(), practice: true)).apply()
        XCTAssertEqual(result.status, .practiceComplete, "\(result.notes) | \(steps.joined(separator: " | "))")
        let sms = try await page("window.__sms === true") as? Bool
        XCTAssertEqual(sms, false)
    }

    /// careerspage.io: the whole form is a resume drop zone (its file input hidden), an "I'm not a robot" box and
    /// "APPLY". APPLY sends the form, so it isn't a way in; a real run stops before it because of the robot box.
    static let dropZoneOnly = """
        <a href="#">BACK TO JOB DESCRIPTION</a><h1>Java Developer</h1><p>New York</p>
        <form id="f" onsubmit="window.__sent = true; return false">
          <div class="form-group"><label for="application_resume">Resume *</label>
            <div class="drop" style="border:1px dashed #999;padding:20px" onclick="document.getElementById('application_resume').click()">
              Drag &amp; Drop your resume here or click to upload</div>
            <input type="file" id="application_resume" name="application[resume]" accept=".pdf,.docx" style="display:none" required></div>
          <iframe title="reCAPTCHA" width="304" height="78" src="https://fixtures.test/recaptcha/api2/anchor?ar=1&amp;k=test"></iframe>
          <button type="submit" class="btn">APPLY</button>
        </form>
        """

    /// Workable's required "Photo": a file the person never gave the app, said so in plain words.
    func testARequiredPhotoTheAppDoesntHave() async throws {
        try await web.loadTestHTML("""
            <form onsubmit="window.__sent = true; return false">
              <label for="fn">First name *</label><input id="fn" required>
              <div><label for="ph">Photo</label> <span>Choose file</span><input type="file" id="ph" name="avatar" accept="image/*" required></div>
              <div><label for="cv">Resume</label><input type="file" id="cv" name="resume" required></div>
              <button type="submit">Submit application</button></form>
            """, base: URL(string: "https://apply.example.test/acme/j/1/apply/")!)
        let result = try await GenericHandler(web: web, ctx: context(FakeModel(), practice: true)).apply()
        XCTAssertEqual(result.status, .failedForm, "\(result.notes) | \(steps.joined(separator: " | "))")
        XCTAssertTrue(result.notes.contains("“Photo”, which you haven't given the app"), result.notes)
        XCTAssertFalse(result.notes.contains("Choose file"), result.notes)
    }

    /// Workable's phone box (intl-tel-input), set to Peru (+51) from where the computer is, and reading a US number's
    /// "51" as Peru's code: the country is set to the number's own before the number goes in, and a number the site
    /// spoiled earlier ("25550142", left in its saved draft) isn't taken for the person's.
    func testAPhoneBoxWithItsOwnCountryList() async throws {
        try await web.loadTestHTML("""
            <form onsubmit="window.__sent = true; return false">
              <label for="fn">First name *</label><input id="fn" required>
              <label id="phone_label" for="input_phone">Phone</label>
              <div class="iti iti--show-flags">
                <div class="iti__country-container">
                  <button type="button" class="iti__selected-country" aria-expanded="false" aria-haspopup="dialog"
                    aria-controls="iti-0__country-selector" aria-label="Change country for phone number, currently selected Peru (+51)" title="Peru">
                    <div class="iti__flag iti__pe"></div><div class="iti__selected-dial-code">+51</div></button>
                  <div id="iti-0__country-selector" class="iti__hide" role="dialog"><input class="iti__search-input" type="search">
                    <ul class="iti__country-list" role="listbox">
                      <li class="iti__country" role="option" data-dial-code="1" data-country-code="ca"><span class="iti__country-name">Canada</span></li>
                      <li class="iti__country" role="option" data-dial-code="51" data-country-code="pe"><span class="iti__country-name">Peru (Perú)</span></li>
                      <li class="iti__country" role="option" data-dial-code="1" data-country-code="us"><span class="iti__country-name">United States</span></li>
                    </ul></div></div>
                <input type="tel" id="input_phone" name="phone" aria-labelledby="phone_label" class="iti__tel-input" value="25550142"></div>
              <button type="submit">Submit application</button></form>
            <script>
              const btn = document.querySelector('.iti__selected-country'), box = document.getElementById('iti-0__country-selector');
              const list = box.querySelector('ul'), phone = document.getElementById('input_phone');
              let country = 'pe';
              const pick = e => {
                const li = e.target.closest('.iti__country'); if (!li) return;
                country = li.dataset.countryCode;
                document.querySelector('.iti__selected-dial-code').textContent = '+' + li.dataset.dialCode;
                btn.title = li.textContent; btn.setAttribute('aria-expanded', 'false'); box.classList.add('iti__hide');
                list.removeEventListener('click', pick);
              };
              // Like intl-tel-input: the list takes clicks only while it's open.
              btn.addEventListener('click', () => { box.classList.remove('iti__hide'); btn.setAttribute('aria-expanded', 'true'); list.addEventListener('click', pick); });
              // Like Workable: a number typed under Peru loses Peru's code in front.
              const spoil = () => { const d = phone.value.replace(/\\D/g, ''); if (country === 'pe' && d.startsWith('51')) phone.value = d.slice(2); };
              phone.addEventListener('input', spoil); phone.addEventListener('change', spoil); phone.addEventListener('blur', spoil);
            </script>
            """, base: URL(string: "https://apply.example.test/acme/j/1/apply/")!)
        var profile = Fixture.profile
        profile.personal.phone = "512-555-0142"
        let result = try await GenericHandler(web: web, ctx: context(FakeModel(), practice: true, profile: profile)).apply()
        XCTAssertEqual(result.status, .practiceComplete, "\(result.notes) | \(steps.joined(separator: " | "))")
        XCTAssertTrue(steps.contains("Set the phone's country code to United States (+1)"), steps.joined(separator: " | "))
        let phone = try await page("document.getElementById('input_phone').value.replace(/\\D/g, '')") as? String
        XCTAssertEqual(phone, "5125550142")
        let dial = try await page("document.querySelector('.iti__selected-dial-code').textContent") as? String
        XCTAssertEqual(dial, "+1")
    }

    /// Pinpoint's form: the name boxes are in the page, the phone and address boxes drawn a moment later. They're
    /// answered too before the final Submit.
    func testQuestionsDrawnAfterThePageWasRead() async throws {
        try await web.loadTestHTML("""
            <form onsubmit="window.__sent = true; return false">
              <label for="fn">First Name</label><input id="fn" required>
              <div id="later"></div>
              <button type="submit">Submit Application</button></form>
            <script>
              setTimeout(() => {
                document.getElementById('later').innerHTML = '<label for="ph">Phone</label><input id="ph" type="tel" required>' +
                  '<label for="town">Town</label><input id="town" required>';
              }, 1200);
            </script>
            """, base: URL(string: "https://acme.example.test/en/postings/1/applications/new")!)
        let result = try await GenericHandler(web: web, ctx: context(FakeModel(), practice: true)).apply()
        XCTAssertEqual(result.status, .practiceComplete, "\(result.notes) | \(steps.joined(separator: " | "))")
        let phone = try await page("document.getElementById('ph').value") as? String
        XCTAssertEqual(phone?.filter(\.isNumber), Fixture.profile.personal.phone.filter(\.isNumber))
        let town = try await page("document.getElementById('town').value") as? String
        XCTAssertEqual(town, Fixture.profile.personal.address.city)
    }

    func testResumeDropZoneIsTheFormAndItsApplyIsNotAWayIn() async throws {
        try await web.loadTestHTML(Self.dropZoneOnly, base: URL(string: "https://careerspage.example.test/acme/java-developer/apply")!)
        let result = try await GenericHandler(web: web, ctx: context(FakeModel(), practice: true)).apply()
        XCTAssertEqual(result.status, .practiceComplete, "\(result.notes) | \(steps.joined(separator: " | "))")
        XCTAssertTrue(result.notes.contains("I'm not a robot"), result.notes)
        let files = try await page("document.getElementById('application_resume').files.length") as? Int
        XCTAssertEqual(files, 1)
        let sent = try await page("window.__sent === true") as? Bool
        XCTAssertEqual(sent, false)
    }

    func testRealRunStopsAtARobotBox() async throws {
        try await web.loadTestHTML(Self.dropZoneOnly, base: URL(string: "https://careerspage.example.test/acme/java-developer/apply")!)
        let result = try await GenericHandler(web: web, ctx: context(FakeModel(), practice: false)).apply()
        XCTAssertEqual(result.status, .failedForm, result.notes)
        XCTAssertTrue(result.notes.contains("I'm not a robot"), result.notes)
        let sent = try await page("window.__sent === true") as? Bool
        XCTAssertEqual(sent, false)
    }

    /// Personio: Submit stays off until Cloudflare's Turnstile check passes, which is the person's to do. A practice
    /// run ends there; a real run stops and says why. Once the check has passed, it's no robot box.
    func testASecurityCheckKeepsSubmitOff() async throws {
        let html = """
            <form onsubmit="window.__sent = true; return false"><label for="fn">First</label><input id="fn">
            <label for="em">Email*(required)</label><input id="em" required>
            <input type="hidden" name="cf-turnstile-response" id="cf" value="">
            <button type="submit" disabled>Submit Application</button></form>
            """
        try await web.loadTestHTML(html, base: URL(string: "https://acme.jobs.personio.test/job/1/apply")!)
        let practice = try await GenericHandler(web: web, ctx: context(FakeModel(), practice: true)).apply()
        XCTAssertEqual(practice.status, .practiceComplete, "\(practice.notes) | \(steps.joined(separator: " | "))")
        try await web.loadTestHTML(html, base: URL(string: "https://acme.jobs.personio.test/job/1/apply")!)
        let real = try await GenericHandler(web: web, ctx: context(FakeModel(), practice: false)).apply()
        XCTAssertEqual(real.status, .failedForm, real.notes)
        XCTAssertTrue(real.notes.contains("security check"), real.notes)
        _ = try await page("(document.getElementById('cf').value = 'token', true)")
        let passed = await web.hasRobotBox()
        XCTAssertFalse(passed)
    }

    /// Zoho's picture check ("Type below image text" under a captcha image): the app leaves it to the person, so a
    /// practice run says a real run stops there, and a real run stops before sending. The reCAPTCHA notice beside a
    /// box ("protected by reCAPTCHA") is no such check.
    func testAPictureCheckIsThePersons() async throws {
        let html = """
            <form onsubmit="window.__sent = true; return false"><label for="fn">First Name</label><input id="fn" required>
            <div class="captcha"><img src="/recruit/Captcha?id=1" alt=""><div><label for="cp">Type below image text</label>
              <input id="cp" name="enterdigest" required></div></div>
            <button type="submit">Submit</button></form>
            """
        try await web.loadTestHTML(html, base: URL(string: "https://acme.zohorecruit.test/jobs/Careers/1/apply")!)
        let practice = try await GenericHandler(web: web, ctx: context(FakeModel(default: ("Backend", .high)), practice: true)).apply()
        XCTAssertEqual(practice.status, .practiceComplete, "\(practice.notes) | \(steps.joined(separator: " | "))")
        XCTAssertTrue(practice.notes.contains("security check"), practice.notes)
        let typed = try await page("document.getElementById('cp').value") as? String
        XCTAssertEqual(typed, "")
        try await web.loadTestHTML(html, base: URL(string: "https://acme.zohorecruit.test/jobs/Careers/1/apply")!)
        let real = try await GenericHandler(web: web, ctx: context(FakeModel(default: ("Backend", .high)), practice: false)).apply()
        XCTAssertEqual(real.status, .failedForm, real.notes)
        let sent = try await page("window.__sent === true") as? Bool
        XCTAssertEqual(sent, false)
        try await web.loadTestHTML("""
            <form><label for="em">Email</label><div><input id="em"><small>This site is protected by reCAPTCHA and the Google Privacy Policy.</small></div></form>
            """, base: URL(string: "https://acme.example.test/apply")!)
        let notice = await web.hasRobotBox()
        XCTAssertFalse(notice)
    }

    /// One application reached through several LinkedIn postings (Mintive's twice, Haystack's three times in one practice
    /// run, each gone through again): the same once what only tracks the visit is dropped. Not a careers home page
    /// different postings share, nor another job on the same site.
    func testTheSameApplicationThroughAnotherPosting() throws {
        let key = { (s: String) in JobRunner.applicationKey(URL(string: s)) }
        XCTAssertEqual(key("https://haystackapp.io/apply/802b2ef9-e272-4c00-aae9-9cd7fb6033ea?src=onboarded&funnel_source=direct"),
                       key("https://haystackapp.io/apply/802b2ef9-e272-4c00-aae9-9cd7fb6033ea?src=onboarded&funnel_source=job-alert"))
        XCTAssertEqual(key("https://jobs.ashbyhq.com/Mintive/ad7b0ef8-a8f2-4f47-b7f2-01063179d48a/application?utm_source=3kKdvyQlEg"),
                       key("https://jobs.ashbyhq.com/mintive/ad7b0ef8-a8f2-4f47-b7f2-01063179d48a/application"))
        XCTAssertNotEqual(key("https://machinele.com/view_job?mode=apply&id=38813"), key("https://machinele.com/view_job?mode=apply&id=39063"))
        XCTAssertNotNil(key("https://machinele.com/view_job?mode=apply&id=38813"))
        XCTAssertNil(key("https://www.acme.test/careers?utm_source=linkedin"), "a page that names no job")

        let home = try TestHome()
        home.db.upsertJob("1", status: .applied, title: "Engineer", company: "Mintive",
                          externalURL: "https://jobs.ashbyhq.com/Mintive/ad7b0ef8-a8f2-4f47-b7f2-01063179d48a/application?utm_source=x")
        home.db.upsertJob("2", status: .practiceComplete, title: "Engineer", company: "Haystack",
                          externalURL: "https://haystackapp.io/apply/802b2ef9-e272-4c00-aae9-9cd7fb6033ea")
        XCTAssertEqual(home.db.appliedApplicationKeys(), [key("https://jobs.ashbyhq.com/mintive/ad7b0ef8-a8f2-4f47-b7f2-01063179d48a/application")!],
                       "only what was sent")
    }

    /// MeeBoss: pressing on brings up hCaptcha's "I am human" over the page, so nothing moves. It's said as the human
    /// check it is (not "the form didn't move on"), and the cloud AI isn't asked about it.
    func testAHumanCheckThatHoldsThePageUp() async throws {
        try await web.loadTestHTML("""
            <form onsubmit="return false"><label for="fn">First name</label><input id="fn" value="Jane">
            <button type="button" onclick="document.getElementById('hc').style.display = 'block'">Continue</button></form>
            <div id="hc" style="display:none"><iframe style="width:300px;height:80px" title="hCaptcha checkbox"
              src="https://newassets.hcaptcha.com.invalid/hcaptcha.com/captcha/v1/static/hcaptcha.html#frame=checkbox&amp;id=1"></iframe></div>
            """, base: URL(string: "https://meeboss.test/job?id=1")!)
        let cloud = FakeModel(default: ("", .high))
        let result = try await GenericHandler(web: web, ctx: context(FakeModel(default: ("Backend", .high)), practice: true, helper: AIService(model: cloud))).apply()
        XCTAssertEqual(result.status, .failedForm, "\(result.notes) | \(steps.joined(separator: " | "))")
        XCTAssertTrue(result.notes.contains("“I'm not a robot” check"), result.notes)
        XCTAssertTrue(cloud.prompts.isEmpty, "the cloud AI isn't asked about a human check")
    }

    /// Acclaim's careers page has "Apply via email" and no form: said plainly, with the address, and nobody is asked.
    func testAnApplicationByEmailOnly() async throws {
        try await web.loadTestHTML("""
            <h1>Software Engineer</h1><p>Austin, TX (Hybrid)</p>
            <a href="mailto:careers@acclaim.test?subject=Application%3A%20Software%20Engineer">Apply via email</a>
            <p>About Acclaim</p><a href="mailto:press@acclaim.test">Press</a>
            """, base: URL(string: "https://www.acclaim.test/company/careers/software-engineer")!)
        let cloud = FakeModel(default: ("", .high))
        let result = try await GenericHandler(web: web, ctx: context(FakeModel(), practice: true, helper: AIService(model: cloud))).apply()
        XCTAssertEqual(result.status, .failedForm, "\(result.notes) | \(steps.joined(separator: " | "))")
        XCTAssertTrue(result.notes.contains("by email, to careers@acclaim.test"), result.notes)
        XCTAssertTrue(cloud.prompts.isEmpty, "the cloud AI isn't asked about a page with no form")
    }

    /// Rippling at AbsenceSoft: "Apply" stays off until "Do you have any connections at …?" is answered, though the
    /// form doesn't mark it required. Neither AI can answer it, so it's the person's question, not a form error.
    func testADisabledButtonWaitingOnAQuestionOnlyThePersonCanAnswer() async throws {
        let html = """
            <form onsubmit="window.__sent = true; return false"><label for="fn">First name</label><input id="fn" required>
            <fieldset><legend>Do you have any connections at Acme?</legend>
            <label><input type="radio" name="c" value="Yes"> Yes</label><label><input type="radio" name="c" value="No"> No</label></fieldset>
            <button type="submit" id="go" disabled>Apply</button></form>
            <script>document.querySelectorAll('input[name=c]').forEach(r => r.addEventListener('change', () => { go.disabled = false; }));</script>
            """
        try await web.loadTestHTML(html, base: URL(string: "https://ats.rippling.test/acme/jobs/1/apply")!)
        let result = try await GenericHandler(web: web, ctx: context(FakeModel(), practice: true)).apply()
        XCTAssertEqual(result.status, .needsAnswer, "\(result.notes) | \(steps.joined(separator: " | "))")
        XCTAssertTrue(result.notes.contains("connections at Acme"), result.notes)
        let sent = try await page("window.__sent === true") as? Bool
        XCTAssertEqual(sent, false)
    }

    /// ADP: Continue opens "Where would you like to receive a verification code?" with the phone and the email drawn as
    /// web components (role=radio, no <input>), and its own "Send". The email is chosen and Send pressed, not Continue
    /// again; then the emailed code is what's needed (here, with email not connected, the run says so).
    func testWhereToSendAVerificationCode() async throws {
        let html = """
            <script>
            customElements.define('x-radio', class extends HTMLElement {
              constructor() { super(); const s = this.attachShadow({mode: 'open'});
                s.innerHTML = '<div role="radio" aria-checked="false" tabindex="0" name="IDENTIFIER_GROUP"><slot></slot></div>';
                const r = s.firstElementChild;
                r.addEventListener('click', () => { document.querySelectorAll('x-radio').forEach(x => x.shadowRoot.firstElementChild.setAttribute('aria-checked', 'false'));
                  r.setAttribute('aria-checked', 'true'); window.__choice = this.getAttribute('value'); }); }
            });
            </script>
            <div id="page"><label for="fn">First Name</label><input id="fn"><label for="ln">Last Name</label><input id="ln">
            <label for="em">Email</label><input id="em"><label for="mo">Mobile Number</label><input id="mo">
            <button type="button" id="cont">Continue</button></div>
            <div id="ask" style="display:none"><div><label>Where would you like to receive a verification code?</label></div>
              <div><x-radio value="CELL_PHONE">+1-512-555-0142</x-radio><x-radio value="EMAIL">jane.doe@example.com</x-radio>
              <div><button type="button" id="send">Send</button></div></div></div>
            <div id="code" style="display:none"><label for="vc">Verification code</label><input id="vc" maxlength="6"><button type="button">Verify</button></div>
            <script>
            cont.addEventListener('click', () => { window.__continues = (window.__continues || 0) + 1; ask.style.display = 'block'; });
            send.addEventListener('click', () => { if (!window.__choice) return; window.__sentTo = window.__choice; ask.style.display = 'none'; page.style.display = 'none'; code.style.display = 'block'; });
            </script>
            """
        try await web.loadTestHTML(html, base: URL(string: "https://workforcenow.adp.test/mascsr/recruitment.html?jobId=1")!)
        let result = try await GenericHandler(web: web, ctx: context(FakeModel(), practice: true)).apply()
        let sentTo = try await page("window.__sentTo || ''") as? String
        XCTAssertEqual(sentTo, "EMAIL", "\(result.notes) | \(steps.joined(separator: " | "))")
        let continues = try await page("window.__continues || 0") as? Int
        XCTAssertEqual(continues, 1)
        XCTAssertEqual(result.status, .failedOTPTimeout, result.notes)
        XCTAssertTrue(result.notes.contains("emailed a code"), result.notes)
    }

    static var mailSecrets: Secrets {
        var secrets = Secrets()
        (secrets.imapUser, secrets.imapPassword, secrets.imapHost) = ("jane.doe@example.com", "abcdabcdabcdabcd", "imap.example.com")
        secrets.portalPassword = "Portal-Pass-2026!"
        return secrets
    }

    static func plainMail(from: String, subject: String, _ body: String) -> Data {
        Data("""
            From: \(from)
            To: jane.doe@example.com
            Subject: \(subject)
            Date: \(rfc2822(Date()))
            Content-Type: text/plain; charset="utf-8"
            MIME-Version: 1.0

            \(body)
            """.replacingOccurrences(of: "\n", with: "\r\n").utf8)
    }

    /// A Workday posting that's been taken down says so instead of "no Next or Submit button".
    func testWorkdayPostingThatIsGone() async throws {
        try await web.loadTestHTML("""
            <header><button data-automation-id="utilityButtonSignIn">Sign In</button></header>
            <main><p>The page you are looking for doesn't exist.</p><a href="/jobs">Search for Jobs</a></main>
            """, base: URL(string: "https://example.wd1.myworkdayjobs.com/en-US/Careers/job/Gone_JR1")!)
        let result = try await WorkdayHandler(web: web, ctx: context(FakeModel(), practice: true)).apply()
        XCTAssertEqual(result.status, .failedForm)
        XCTAssertTrue(result.notes.contains("no longer"), result.notes)
    }

    /// Kula (Shinkei): the form ends with "Apply for this position", a plain button, under the questions. It's the
    /// Submit (the run stopped with "No Next or Submit button").
    func testApplyForThisPositionUnderTheQuestionsIsTheSubmit() async throws {
        try await web.loadTestHTML("""
            <div role="tablist"><button type="button">Job details</button><button type="button">Application form</button></div>
            <form onsubmit="return false"><label for="fn">First name</label><input id="fn" required>
              <label for="ln">Last name</label><input id="ln" required>
              <button type="button" class="chakra-button" onclick="window.__sent = true">Apply for this position</button></form>
            """, base: URL(string: "https://careers.kula.example/shinkei/53417-software-engineer/apply")!)
        let result = try await GenericHandler(web: web, ctx: context(FakeModel(), practice: true)).apply()
        XCTAssertEqual(result.status, .practiceComplete, "\(result.notes) | \(steps.joined(separator: " | "))")
        let sent = try await page("window.__sent === true") as? Bool
        XCTAssertEqual(sent, false, "a practice run never presses it")
    }

    /// Adzuna's chat: "Would you like to apply for the job?" with "Yes, apply now" and "No, thanks". "Yes, apply now" is
    /// the way in (the run stopped with "No application form").
    func testAChatsYesApplyNow() async throws {
        try await web.loadTestHTML("""
            <main><h2>Java Full Stack Developer</h2><p>Would you like to apply for the job?</p>
            <button onclick="document.getElementById('f').style.display='block'">No, thanks</button>
            <button onclick="this.dataset.pressed='1'; document.getElementById('f').style.display='block'">Yes, apply now</button>
            <form id="f" style="display:none"><label for="a">First name</label><input id="a"><label for="b">Last name</label><input id="b">
              <label for="c">Email</label><input id="c" type="email"></form></main>
            """, base: URL(string: "https://www.adzuna.example.test/details/5961885747")!)
        _ = try await SiteRouter.reachApplication(web, step: { _ in })
        let pressed = try await page("document.querySelector('[data-pressed]') ? document.querySelector('[data-pressed]').innerText : ''") as? String
        XCTAssertEqual(pressed, "Yes, apply now")
    }

    /// A site behind a service that turns away automated browsers (CGI, behind Radware): says so plainly.
    func testSiteThatTurnsAwayAutomatedBrowsers() async throws {
        try await web.loadTestHTML("<p>Please verify you are a human</p>", base: URL(string: "https://validate.perfdrive.com/challenge")!)
        let reach = try await SiteRouter.reachApplication(web, step: { _ in })
        guard case .stop(let note) = reach else { return XCTFail("went on") }
        XCTAssertTrue(note.contains("automated browsers"), note)
    }

    /// A careers site that hands off to "Sign in with Apple" (IBM, through GitHub): nothing is typed there.
    func testNeverSignsInToAppleOrGoogle() async throws {
        try await web.loadTestHTML("""
            <form><label for="acc">Email or Phone Number</label><input id="acc" type="text">
            <label for="pw">Password</label><input id="pw" type="password"><button type="submit">Sign In</button></form>
            """, base: URL(string: "https://appleid.apple.com/auth/authorize")!)
        var secrets = Secrets()
        secrets.portalPassword = "Portal-Pass-2026!"
        let result = try await GenericHandler(web: web, ctx: context(FakeModel(), practice: true, secrets: secrets)).apply()
        XCTAssertEqual(result.status, .failedForm)
        XCTAssertTrue(result.notes.contains("Apple"), result.notes)
        let typed = try await page("document.getElementById('acc').value + document.getElementById('pw').value") as? String
        XCTAssertEqual(typed, "")
        let reach = try await SiteRouter.reachApplication(web, step: { _ in })
        guard case .stop = reach else { return XCTFail("went on at Apple's sign-in page") }
        XCTAssertEqual(SiteRouter.identityProvider(URL(string: "https://accounts.google.com/v3/signin")), "Google")
        XCTAssertEqual(SiteRouter.identityProvider(URL(string: "https://login.microsoftonline.com/common")), "Microsoft")
        XCTAssertNil(SiteRouter.identityProvider(URL(string: "https://passport.amazon.jobs/idprism/migrate")))
        XCTAssertNil(SiteRouter.identityProvider(URL(string: "https://jpmc.fa.oraclecloud.com/hcmUI")))
    }

    nonisolated static func rfc2822(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
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

@MainActor
extension HandlerTests {
    /// Paylocity reads an uploaded resume and fills the form from it a moment later, misreading it ("Peru" for Country,
    /// which swaps City for Locality; the last name as the first). Its "Fill out application with my resume" is
    /// unticked first and the form's own resume box used, not the popup's that always reads it; the start date goes in
    /// as a date.
    func testSiteIsNotLetToFillTheFormFromTheResume() async throws {
        try await web.loadTestHTML("""
            <form onsubmit="return false">
              <div role="dialog"><p>Apply with resume</p>
                <label for="pop">Upload your resume and we'll automatically fill out your application</label><input type="file" id="pop"></div>
              <label><input type="checkbox" id="auto" checked> Fill out application with my resume</label>
              <label for="res">Resume</label><input type="file" id="res">
              <label for="fn">First Name</label><input id="fn" required>
              <label for="country">Country</label><select id="country"><option>United States</option><option>Peru</option></select>
              <div id="addr"><label for="city">City</label><input id="city" required></div>
              <label for="start">Available to Start</label>
              <input id="start" type="text" placeholder="MM/DD/YYYY" onfocus="this.type='date'" onblur="this.type='text'">
              <button type="submit">Submit application</button>
            </form>
            <script>
            const parse = () => setTimeout(() => {
              if (!document.getElementById('auto').checked) return;
              document.getElementById('country').value = 'Peru';
              document.getElementById('addr').innerHTML = '<label for="loc">Locality</label><input id="loc" value="Lima">';
              document.getElementById('fn').value = 'Doe';
            }, 1200);
            document.getElementById('pop').onchange = () => { window.__pop = true; parse(); };
            document.getElementById('res').onchange = parse;
            </script>
            """, base: URL(string: "https://recruiting.paylocity.com/Recruiting/Jobs/Apply/1")!)
        let result = try await GenericHandler(web: web, ctx: context(FakeModel(), practice: true)).apply()
        XCTAssertEqual(result.status, .practiceComplete, "\(result.notes) | \(steps.joined(separator: " | "))")
        try await web.sleep(1.5)
        let state = try await page("[document.getElementById('auto').checked, !!window.__pop, document.getElementById('res').files.length, " +
                                   "document.getElementById('country').value, (document.getElementById('city') || {value: 'gone'}).value, " +
                                   "document.getElementById('fn').value, document.getElementById('start').value]") as? [Any]
        XCTAssertEqual(state?[0] as? Bool, false, "the box to fill the form from the resume is unticked")
        XCTAssertEqual(state?[1] as? Bool, false, "the popup's upload isn't used")
        XCTAssertEqual((state?[2] as? NSNumber)?.intValue, 1, "the resume is in the form's box")
        XCTAssertEqual(state?[3] as? String, "United States")
        XCTAssertEqual(state?[4] as? String, "Austin")
        XCTAssertEqual(state?[5] as? String, "Jane")
        XCTAssertTrue(Regex(#"^\d{4}-\d{2}-\d{2}$"#).matches(state?[6] as? String ?? ""), "\(String(describing: state?[6]))")
    }

    /// iCIMS draws each step in a frame from the same site and turns the frame's page, opened by itself, back into the
    /// page around the frame: the app works inside the frame (its clicks land where the frame sits on the page).
    func testWorksInsideTheICIMSFrame() async throws {
        let step2 = #"<form onsubmit='return false'><label for='why'>Why do you want to work here?</label><textarea id='why'></textarea>"#
            + #"<button type='submit'>Submit application</button></form>"#
        let step1 = """
            <html><body><h2>Enter Your Information</h2><form onsubmit="return false"><label for="em">Email</label>
            <input id="em" type="email" name="loginName"><button id="next" type="button">Next</button></form>
            <script>document.getElementById('next').addEventListener('click', e => {
              parent.__email = document.getElementById('em').value; parent.__trusted = e.isTrusted;
              document.body.innerHTML = "\(step2)"; });</script></body></html>
            """
        let srcdoc = step1.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        try await web.loadTestHTML("""
            <div style="height: 260px">Garmin careers</div>
            <iframe id="icims_content_iframe" style="margin-left: 120px; width: 600px; height: 500px; border: 3px solid #888" srcdoc="\(srcdoc)"></iframe>
            """, base: URL(string: "https://careers-garmin.icims.com/jobs/16587/login")!)
        try await web.sleep(1)
        let result = try await GenericHandler(web: web, ctx: context(FakeModel(["Why do you want to work here?": ("The products.", .high)]),
                                                                     practice: true)).apply()
        XCTAssertEqual(result.status, .practiceComplete, "\(result.notes) | \(steps.joined(separator: " | "))")
        let email = try await page("window.__email") as? String
        XCTAssertEqual(email, "jane.doe@example.com", steps.joined(separator: " | "))
        if web.cloud != nil || web.webView.window != nil {
            let trusted = try await page("window.__trusted") as? Bool
            XCTAssertEqual(trusted, true, "a real click, where the frame is on the page")
        }
    }

    /// MANTECH (Avature): a sign-in box beside "From Device" (a hidden resume box that does nothing by itself),
    /// "Without Resume" and "Apply with Indeed". The resume box is tried once; then "Without Resume", the sign-up page,
    /// and the application.
    func testTakesTheWayInWithoutResumeWhenTheResumeBoxDoesNothing() async throws {
        try await web.loadTestHTML("""
            <h1>Mobile Application Developer</h1>
            <form onsubmit="return false"><h3>Already Registered?</h3>
              <label for="u">Username</label><input id="u" name="username"><label for="pw">Password</label><input id="pw" type="password" name="password">
              <button type="submit">Log in</button></form>
            <form><input type="file" id="resumeFile" name="resumeFile" style="display:none"></form>
            <ul><li><a href="#" id="dev">From Device</a></li><li><a href="#" id="wo">Without Resume</a></li><li><a href="#">Apply with Indeed</a></li></ul>
            <template id="register"><form onsubmit="return false"><h2>Create your profile</h2>
              <label for="em">Email</label><input id="em" type="email" required>
              <label for="p1">Password</label><input id="p1" type="password" required>
              <label for="p2">Confirm password</label><input id="p2" type="password" required>
              <button type="button" id="create">Create account</button></form></template>
            <template id="last"><form onsubmit="return false"><label for="why">Why MANTECH?</label><textarea id="why"></textarea>
              <button type="submit">Submit application</button></form></template>
            <script>
            const tpl = { register: document.getElementById('register').innerHTML, last: document.getElementById('last').innerHTML };
            document.addEventListener('click', e => {
              const t = e.target.closest('a, button');
              if (!t) return;
              if (t.id === 'wo') { e.preventDefault(); document.body.innerHTML = tpl.register; }
              if (t.id === 'create') { window.__registered = document.getElementById('em').value; document.body.innerHTML = tpl.last; }
            });
            </script>
            """, base: URL(string: "https://careers.mantech.example/en_US/careers/ApplicationMethods?jobId=67066")!)
        var secrets = Secrets()
        secrets.portalPassword = "Portal-Pass-2026!"
        let result = try await GenericHandler(web: web, ctx: context(FakeModel(["Why MANTECH?": ("The mission.", .high)]), practice: true,
                                                                     secrets: secrets)).apply()
        XCTAssertEqual(result.status, .practiceComplete, "\(result.notes) | \(steps.joined(separator: " | "))")
        XCTAssertTrue(steps.contains { $0.contains("Without Resume") }, steps.joined(separator: " | "))
        let registered = try await page("window.__registered") as? String
        XCTAssertEqual(registered, "jane.doe@example.com")
    }

    /// MetLife (Avature): "Already registered?" beside "First time here?". "From Device" shows the hidden resume box
    /// with its own Continue; nothing moves until that's pressed. No sign-in and no password reset for a new applicant.
    func testFirstTimeApplicantThroughFromDeviceAndContinue() async throws {
        try await web.loadTestHTML("""
            <h1>Software Engineer</h1>
            <form onsubmit="return false"><h3>Already registered?</h3>
              <label for="u">Email</label><input id="u" name="username"><label for="pw">Password</label><input id="pw" type="password" name="password">
              <a href="/ResetPassword">Forgot your password?</a><button type="submit">Log In</button></form>
            <h3>First time here?</h3>
            <ul><li><a href="#" role="button" id="methodButton--file" data-registermethod="file">From Device</a></li>
              <li><a href="#" role="button" id="methodButton--paste">Copy &amp; Paste</a></li></ul>
            <form onsubmit="return false"><fieldset id="fs" style="display:none">
              <label for="resumeFile">From Device *</label><input id="resumeFile" type="file" name="resumeFile" style="display:none">
              <button id="uploadFileResume" type="submit">Continue</button></fieldset></form>
            <template id="register"><form onsubmit="return false"><h2>Create your profile</h2>
              <label for="em">Email</label><input id="em" type="email" required>
              <label for="p1">Password</label><input id="p1" type="password" required>
              <label for="p2">Confirm password</label><input id="p2" type="password" required>
              <button type="button" id="create">Create account</button></form></template>
            <template id="last"><form onsubmit="return false"><label for="why">Why MetLife?</label><textarea id="why"></textarea>
              <button type="submit">Submit application</button></form></template>
            <script>
            const tpl = { register: document.getElementById('register').innerHTML, last: document.getElementById('last').innerHTML };
            document.addEventListener('click', e => {
              const t = e.target.closest('a, button');
              if (!t) return;
              if (t.id === 'methodButton--file') { e.preventDefault(); document.getElementById('fs').style.display = 'block'; }
              if (t.id === 'uploadFileResume' && document.getElementById('resumeFile').files.length) { document.body.innerHTML = tpl.register; }
              if (t.id === 'create') { window.__registered = document.getElementById('em').value; document.body.innerHTML = tpl.last; }
              if (/forgot/i.test(t.innerText)) { e.preventDefault(); window.__reset = true; }
            });
            </script>
            """, base: URL(string: "https://www.metlife.example/en_US/ml/ApplicationMethods?jobId=16871")!)
        var secrets = Secrets()
        secrets.portalPassword = "Portal-Pass-2026!"
        let result = try await GenericHandler(web: web, ctx: context(FakeModel(["Why MetLife?": ("The mission.", .high)]), practice: true,
                                                                     secrets: secrets)).apply()
        XCTAssertEqual(result.status, .practiceComplete, "\(result.notes) | \(steps.joined(separator: " | "))")
        XCTAssertTrue(steps.contains("Pressing “From Device”"), steps.joined(separator: " | "))
        XCTAssertTrue(steps.contains("Pressing “Continue”"), steps.joined(separator: " | "))
        XCTAssertFalse(steps.contains { $0.contains("Signing in") || $0.contains("reset") }, steps.joined(separator: " | "))
        let registered = try await page("window.__registered") as? String
        XCTAssertEqual(registered, "jane.doe@example.com")
    }

    /// Taleo (Dassault): "Create an account" reloads the page, and the sign-up comes back with "The value entered in
    /// the field “User Name” is invalid" a few seconds later. The user name is the email, which it takes; the account
    /// is recorded once the sign-up goes through.
    func testASignUpThatReloadsTakesTheEmailAsUserName() async throws {
        let result = try await taleoSignUp(alwaysReject: false)
        XCTAssertEqual(result.status, .practiceComplete, "\(result.notes) | \(steps.joined(separator: " | "))")
        let registered = try await page("window.__registered") as? String
        XCTAssertEqual(registered, "jane.doe@example.com")
        XCTAssertEqual(home.db.accounts().map(\.how), [.made])
    }

    /// The same sign-up that never goes through: no account recorded (a later run would sign in to nothing and reset
    /// a password that doesn't exist), and the site's words in the note.
    func testASignUpThatComesBackIsNoAccount() async throws {
        let result = try await taleoSignUp(alwaysReject: true)
        XCTAssertNotEqual(result.status, .practiceComplete, "\(result.notes) | \(steps.joined(separator: " | "))")
        XCTAssertTrue(home.db.accounts().isEmpty, "\(home.db.accounts().map(\.host)) | \(steps.joined(separator: " | "))")
        XCTAssertFalse(steps.contains { $0.hasPrefix("Made an account") }, steps.joined(separator: " | "))
    }

    private func taleoSignUp(alwaysReject: Bool) async throws -> ApplyResult {
        try await web.loadTestHTML("""
            <h2>New User Registration</h2><div id="err"></div>
            <form onsubmit="return false"><h3>Create an account</h3>
              <label for="un">User Name</label><input id="un" required>
              <label for="p1">Password</label><input id="p1" type="password" required>
              <label for="p2">Re-enter Password</label><input id="p2" type="password" required>
              <label for="em">Email Address</label><input id="em" type="email" required>
              <label for="em2">Re-enter Email Address</label><input id="em2" type="email" required>
              <button type="button" id="create">Register</button></form>
            <template id="last"><form onsubmit="return false"><label for="why">Why Dassault?</label><textarea id="why"></textarea>
              <button type="submit">Submit application</button></form></template>
            <script>
            const reject = \(alwaysReject);
            const last = document.getElementById('last').innerHTML;
            document.getElementById('create').addEventListener('click', () => {
              const name = document.getElementById('un').value;
              setTimeout(() => {
                if (reject || !name || /[\\s:><()]/.test(name)) {
                  document.getElementById('err').innerHTML = '<span role="alert" class="errorMessage">The value entered in the field "User Name" is invalid. It must not include spaces.</span>';
                } else { window.__registered = name; document.body.innerHTML = last; }
              }, 2500);
            });
            </script>
            """, base: URL(string: "https://talentacquisition.3ds.example/careersection/iam/accessmanagement/register.jsf")!)
        var secrets = Secrets()
        secrets.portalPassword = "Portal-Pass-2026!"
        return try await GenericHandler(web: web, ctx: context(FakeModel(["Why Dassault?": ("The mission.", .high)]), practice: true,
                                                               secrets: secrets)).apply()
    }

    /// Dice: an email step, then "Creating for … Not you?" with a "Sign in" link, which goes back to the email step.
    /// The app had noted an account there that never was; it presses "Sign in" once, then makes the account (the run
    /// went round until "Couldn't get past dice.com's sign-in").
    func testASignUpForAnAccountTheAppWronglyNoted() async throws {
        home.db.noteAccount(host: "www.dice.example", email: "jane.doe@example.com")
        try await web.loadTestHTML("""
            <div id="app"></div>
            <template id="email"><form onsubmit="return false"><h2>Sign in or create an account</h2>
              <label for="e">Email</label><input id="e" type="email" required>
              <button type="button" id="cont">Continue</button></form></template>
            <template id="register"><form onsubmit="return false"><p>Creating for <span id="who"></span> — <a href="#" id="notyou">Not you?</a></p>
              <a href="#" id="signin">Sign in</a>
              <label for="fn">First Name</label><input id="fn" placeholder="John" required>
              <label for="ln">Last Name</label><input id="ln" placeholder="Doe" required>
              <label for="p1">Password</label><input id="p1" type="password" required>
              <label for="p2">Confirm Password</label><input id="p2" type="password" required>
              <button type="button" id="reg">Register</button></form></template>
            <template id="last"><form onsubmit="return false"><label for="why">Why Dice?</label><textarea id="why"></textarea>
              <button type="submit">Submit application</button></form></template>
            <script>
            const show = id => { document.getElementById('app').innerHTML = document.getElementById(id).innerHTML; };
            show('email');
            document.addEventListener('click', e => {
              const t = e.target.closest('a, button');
              if (!t) return;
              e.preventDefault();
              if (t.id === 'cont') { const who = document.getElementById('e').value; show('register'); document.getElementById('who').textContent = who; }
              if (t.id === 'signin' || t.id === 'notyou') { window.__signins = (window.__signins || 0) + 1; show('email'); }
              if (t.id === 'reg') { window.__registered = document.getElementById('fn').value; show('last'); }
            });
            </script>
            """, base: URL(string: "https://www.dice.example/apply/1")!)
        var secrets = Secrets()
        secrets.portalPassword = "Portal-Pass-2026!"
        let result = try await GenericHandler(web: web, ctx: context(FakeModel(["Why Dice?": ("The mission.", .high)]), practice: true,
                                                                     secrets: secrets)).apply()
        XCTAssertEqual(result.status, .practiceComplete, "\(result.notes) | \(steps.joined(separator: " | "))")
        let registered = try await page("window.__registered") as? String
        XCTAssertEqual(registered, "Jane")
        let signins = try await page("window.__signins || 0") as? Int
        XCTAssertEqual(signins, 1)
    }

    /// Dayforce: a privacy statement over the form, with a box to tick and its own Save (greyed out until then). The
    /// popup is answered first; then the form under it.
    func testAnswersAPopupOverTheFormFirst() async throws {
        try await web.loadTestHTML("""
            <form onsubmit="return false" id="app">
              <label for="fn">First Name</label><input id="fn" required>
              <button type="submit" id="next">Submit application</button>
            </form>
            <div class="ant-modal-root"><div class="ant-modal-mask" style="position:fixed;inset:0;background:rgba(0,0,0,.4)"></div>
              <div class="ant-modal-wrap" style="position:fixed;inset:0;display:flex;align-items:center;justify-content:center">
                <div role="dialog" aria-modal="true" aria-labelledby="t" style="background:#fff;width:400px;padding:16px">
                  <div id="t">Acme Privacy Policy</div><p>Please review the policy below.</p>
                  <label><input type="checkbox" id="agree"><span>I agree to the Privacy Statement</span></label>
                  <button type="button">Cancel</button><button type="submit" id="save" disabled>Save</button>
                </div></div></div>
            <script>
              const agree = document.getElementById('agree'), save = document.getElementById('save');
              agree.addEventListener('change', () => { save.disabled = !agree.checked; });
              save.addEventListener('click', () => { window.__agreed = agree.checked; document.querySelector('.ant-modal-root').remove(); });
            </script>
            """, base: URL(string: "https://jobs.dayforcehcm.com/en-US/acme/portal/jobs/1/apply/manualApplication")!)
        let result = try await GenericHandler(web: web, ctx: context(FakeModel(), practice: true)).apply()
        XCTAssertEqual(result.status, .practiceComplete, "\(result.notes) | \(steps.joined(separator: " | "))")
        let agreed = try await page("window.__agreed") as? Bool
        XCTAssertEqual(agreed, true, steps.joined(separator: " | "))
        let first = try await page("document.getElementById('fn').value") as? String
        XCTAssertEqual(first, "Jane")
    }

    /// A careers site whose only way in is another account (Fonzi's "Connect LinkedIn"): the app says so and stops.
    func testStopsWhereTheOnlyWayInIsConnectingLinkedIn() async throws {
        try await web.loadTestHTML("""
            <h2>Connect your LinkedIn</h2><p>We use your LinkedIn to verify your identity and prefill your profile.</p>
            <button type="button">Connect LinkedIn</button>
            """, base: URL(string: "https://talent.example.com/")!)
        let result = try await GenericHandler(web: web, ctx: context(FakeModel(), practice: true)).apply()
        XCTAssertEqual(result.status, .failedForm)
        XCTAssertTrue(result.notes.contains("Connect LinkedIn"), result.notes)
    }

    /// LinkedIn's "Job search safety reminder" after Easy Apply: "Continue applying" opens the form.
    func testEasyApplyGoesPastTheSafetyReminder() async throws {
        try await openEasyApply(query: "?remind=1")
        let result = try await EasyApplyHandler(web: web, ctx: context(Self.easyModel(), practice: true)).apply()
        XCTAssertEqual(result.status, .practiceComplete, "\(result.notes) | \(steps.joined(separator: " | "))")
        let reminded = try await page("window.__reminded") as? Bool
        XCTAssertEqual(reminded, true)
    }
}


/// The cloud AI's part when a form gets stuck: it's shown the page's fields and buttons and says what to press; what
/// worked is remembered for the site.
@MainActor
extension HandlerTests {
    func rescueContext(_ cloud: FakeModel) -> ApplyContext {
        let ai = AIService(model: FakeModel())
        var settings = Store(paths: home.paths).loadSettings()
        settings.practiceMode = true
        return ApplyContext(jobID: "4243", job: Fixture.job, settings: settings, paths: home.paths, profile: Fixture.profile, db: home.db,
                            answerer: Answerer(profile: Fixture.profile, db: home.db, ai: ai), ai: ai,
                            verifier: EmailVerifier(secrets: Secrets(), ai: nil), secrets: Secrets(), practice: true,
                            helper: AIService(model: cloud)) { [weak self] in self?.steps.append($0) }
    }

    /// A form whose only way on is a link the app doesn't know ("Onward ›"), to a page with Submit.
    func openStuckForm() async throws {
        try await web.loadTestHTML("""
            <form onsubmit="return false">
              <label for="fn">First Name</label><input id="fn" required>
              <label for="ln">Last Name</label><input id="ln" required>
              <a href="#" id="go">Onward ›</a> <a href="/other-jobs">See other jobs</a>
            </form>
            <script>
            document.getElementById('go').onclick = e => {
              e.preventDefault();
              window.__first = document.getElementById('fn').value;
              document.body.innerHTML = '<form onsubmit="return false"><label for="why">Anything else?</label><input id="why">' +
                '<button type="submit">Submit Application</button></form>';
            };
            </script>
            """, base: URL(string: "https://careers.example.test/apply/1")!)
    }

    func testTheCloudAIUnsticksAFormAndTheSiteRemembersIt() async throws {
        try await openStuckForm()
        let cloud = FakeModel()
        cloud.ui = { prompt in ["action": "press", "element": buttonNumber(prompt, "Onward ›"), "fixes": [], "reason": "It moves to the next step."] }
        let result = try await GenericHandler(web: web, ctx: rescueContext(cloud)).apply()
        XCTAssertEqual(result.status, .practiceComplete, "\(result.notes) | \(steps.joined(separator: " | "))")
        XCTAssertEqual(cloud.uiPrompts.count, 1)
        let prompt = cloud.uiPrompts.first ?? ""
        XCTAssertTrue(prompt.contains("First Name") && prompt.contains("Onward ›") && prompt.contains("PROBLEM:"), prompt)
        XCTAssertFalse(prompt.contains("jane.doe@example.com") || prompt.contains("555-123-4567"), "the email and phone stay on this Mac")
        let first = try await page("window.__first") as? String
        XCTAssertEqual(first, "Jane", "the page was filled before moving on")
        XCTAssertEqual(home.db.meta("ui-press:careers.example.test"), "Onward › (link)")

        // The next application on the site presses it without asking.
        try await openStuckForm()
        let again = FakeModel()
        let second = try await GenericHandler(web: web, ctx: rescueContext(again)).apply()
        XCTAssertEqual(second.status, .practiceComplete, "\(second.notes) | \(steps.joined(separator: " | "))")
        XCTAssertTrue(again.uiPrompts.isEmpty)
        XCTAssertTrue(steps.contains { $0.contains("which moved careers.example.test's form on before") }, steps.joined(separator: " | "))
    }

    /// ADP's job page: two "Apply" buttons, only the second opens the form. On a page with nothing to send, "Apply" is
    /// the way in, not the final Submit, and the cloud AI is shown both.
    func testTheCloudAIFindsTheApplyButtonThatWorks() async throws {
        try await web.loadTestHTML("""
            <h1>Java Developer</h1><p>Fort Worth, TX</p>
            <button id="a1" type="button">Apply</button>
            <p>About the role: services and APIs.</p>
            <button id="a2" type="button">Apply</button>
            <script>
            document.getElementById('a2').onclick = () => {
              document.body.innerHTML = '<form onsubmit="return false"><label for="fn">First Name</label><input id="fn" required>' +
                '<label for="ln">Last Name</label><input id="ln" required><button type="submit">Submit Application</button></form>';
            };
            </script>
            """, base: URL(string: "https://jobs.example.test/recruitment.html?jobId=1")!)
        let cloud = FakeModel()
        cloud.ui = { prompt in ["action": "press", "element": buttonNumber(prompt, "Apply", nth: 2), "fixes": [], "reason": "The second Apply opens the form."] }
        let result = try await GenericHandler(web: web, ctx: rescueContext(cloud)).apply()
        XCTAssertEqual(result.status, .practiceComplete, "\(result.notes) | \(steps.joined(separator: " | "))")
        XCTAssertTrue(cloud.uiPrompts.first?.contains("Apply (button 2)") ?? false, cloud.uiPrompts.first ?? "")
        let first = try await page("document.getElementById('fn').value") as? String
        XCTAssertEqual(first, "Jane")
    }

    func testTheCloudAIIsNeverLetToSignInWithAnotherAccount() async throws {
        try await web.loadTestHTML("""
            <form onsubmit="return false"><label for="fn">First Name</label><input id="fn" required>
            <a href="#" id="g">Continue with Google</a></form>
            """, base: URL(string: "https://careers.example.test/apply/2")!)
        let cloud = FakeModel()
        cloud.ui = { prompt in ["action": "press", "element": buttonNumber(prompt, "Continue with Google"), "fixes": [], "reason": "Sign in."] }
        let result = try await GenericHandler(web: web, ctx: rescueContext(cloud)).apply()
        XCTAssertEqual(result.status, .failedForm)
        XCTAssertTrue(result.notes.contains("another account"), result.notes)
        XCTAssertNil(home.db.meta("ui-press:careers.example.test"))
    }

    /// New York Life's job page has no Apply: the cloud AI's "Join Talent Network" is a sign-up, not the way in.
    func testTheCloudAIIsNeverLetToJoinATalentNetwork() async throws {
        try await web.loadTestHTML("""
            <h1>Financial Representative</h1><p>About the job…</p><a href="#" id="j" onclick="window.__joined = true">Join Talent Network</a>
            """, base: URL(string: "https://careers.example.test/careers/job/3")!)
        let cloud = FakeModel()
        cloud.ui = { prompt in ["action": "press", "element": buttonNumber(prompt, "Join Talent Network"), "fixes": [], "reason": "It may lead to the form."] }
        let result = try await GenericHandler(web: web, ctx: rescueContext(cloud)).apply()
        XCTAssertEqual(result.status, .failedForm)
        XCTAssertTrue(result.notes.contains("sign-up"), result.notes)
        let joined = try await web.js("return !!window.__joined") as? Bool
        XCTAssertEqual(joined, false)
    }

    func testTheCloudAIsSubmitButtonIsWhereAPracticeRunStops() async throws {
        try await web.loadTestHTML("""
            <form onsubmit="window.__sent = true; return false"><label for="fn">First Name</label><input id="fn" required>
            <a href="#" id="s" onclick="window.__sent = true">Lähetä hakemus</a></form>
            """, base: URL(string: "https://careers.example.test/apply/3")!)
        let cloud = FakeModel()
        cloud.ui = { prompt in ["action": "submit", "element": buttonNumber(prompt, "Lähetä hakemus"), "fixes": [], "reason": "It sends the application."] }
        let result = try await GenericHandler(web: web, ctx: rescueContext(cloud)).apply()
        XCTAssertEqual(result.status, .practiceComplete, result.notes)
        let sent = try await page("window.__sent") as? Bool
        XCTAssertNil(sent)
    }
}

@MainActor
extension HandlerTests {
    /// U.S. Bank's job page names its whole <body> "cookie-popup-top ph-chatbot-parent-body": cookie banners and chat
    /// windows are left alone, not the page that merely mentions them.
    func testAPageWhoseBodyMentionsCookiesAndChat() async throws {
        try await web.loadTestHTML("""
            <body class="job-page cookie-popup-top ph-chatbot-parent-body">
            <h1>Software Engineer 1</h1><a class="btn" href="https://careers.example.test/apply/form">Apply now</a>
            <form><label for="fn">First Name</label><input id="fn"></form>
            <div id="cookie-banner"><label for="c">Cookie choice</label><input id="c"></div>
            </body>
            """, base: URL(string: "https://careers.example.test/job/1")!)
        let fields = await web.extractFields(root: nil, exclude: ApplicationHandler.exclude)
        XCTAssertEqual(fields.map(\.spec.label), ["First Name"])
        let entry = try await web.js(Scripts.tagEntryButton, ["anyButton": false]) as? [String: Any]
        XCTAssertEqual(entry?["name"] as? String, "Apply now")
    }
    /// The page keeps drawing while the browser's window is behind others (ADP's job pages, drawn on animation frames,
    /// stayed blank: WebKit counted the covered window as hidden).
    func testThePageKeepsDrawingBehindOtherWindows() async throws {
        try await web.loadTestHTML("<body><p>Job</p></body>", base: URL(string: "https://careers.example.test/job/1")!)
        let drawn = try await web.js(#"return await Promise.race([new Promise(r => requestAnimationFrame(() => r(true))), new Promise(r => setTimeout(() => r(false), 2000))]);"#) as? Bool
        XCTAssertEqual(drawn, true)
        let state = try await web.js("return document.visibilityState") as? String
        XCTAssertEqual(state, "visible")
    }

    /// SmartRecruiters' one-click form: every box, label and button inside web components, the question and the
    /// button's words slotted in from outside, the upload boxes named only in the page's code.
    func testAFormDrawnInWebComponents() async throws {
        try await web.loadTestHTML("""
            <body><main>
            <x-field id="first"><span slot="label">First name</span>
              <template shadowrootmode="open"><label for="i">* <slot name="label"></slot></label><input id="i" required></template></x-field>
            <x-field id="why"><span slot="label">Are you a citizen or lawful permanent resident?</span>
              <template shadowrootmode="open"><div><label>*<slot name="label"></slot></label>
                <div><div><input role="combobox" aria-controls="menu" aria-autocomplete="list" aria-required="true"></div></div>
                <div role="listbox" id="menu"><x-opt><span>Yes</span><template shadowrootmode="open"><div role="option"><slot></slot></div></template></x-opt>
                  <x-opt><span>No</span><template shadowrootmode="open"><div role="option"><slot></slot></div></template></x-opt></div>
              </div></template></x-field>
            <div data-test="resume-upload-container"><x-drop data-test="resume-upload">
              <template shadowrootmode="open"><div><label for="f">Choose a file or drop it here</label><input type="file" id="f"><p>10MB size limit</p></div></template></x-drop></div>
            <x-button id="next">Next<template shadowrootmode="open"><button type="button"><slot></slot></button></template></x-button>
            </main></body>
            """, base: URL(string: "https://jobs.example.test/oneclick-ui/company/x/publication/1")!)
        let fields = await web.extractFields(root: nil, exclude: ApplicationHandler.exclude)
        XCTAssertEqual(fields.map(\.spec.label), ["* First name", "* Are you a citizen or lawful permanent resident?", "resume upload"])
        XCTAssertEqual(fields.map(\.kind), [.text, .combobox, .file])
        XCTAssertEqual(fields.last?.fileKind, "resume")
        XCTAssertTrue(fields[0].spec.required)
        let next = await web.findButton(nextPattern)
        XCTAssertEqual(next, "Next")
        await web.click(fields[1].selector)
        let options = try await web.js(Scripts.options, ["sel": fields[1].selector]) as? [String]
        XCTAssertEqual(options, ["Yes", "No"])
        let took = await web.upload(fields[2], home.paths.resumeFile)
        XCTAssertTrue(took)
    }

    /// Fiserv's group of boxes named only for the page's code: the question beside it.
    func testAGroupNamedForThePagesCode() async throws {
        try await web.loadTestHTML("""
            <body><form><div class="q"><p>Which of these certifications do you hold?</p>
            <div role="group" aria-label="QUESTIONNAIRE-6-818">
              <label><input type="checkbox" name="c" value="a"> AWS</label><label><input type="checkbox" name="c" value="b"> None</label>
            </div></div></form></body>
            """, base: URL(string: "https://careers.example.test/apply")!)
        let fields = await web.extractFields(root: nil, exclude: ApplicationHandler.exclude)
        XCTAssertEqual(fields.map(\.spec.label), ["Which of these certifications do you hold?"])
        XCTAssertEqual(fields.first?.kind, .checkboxGroup)
    }

    /// U.S. Bank's page for a job that's gone: no form, and the app says the job is closed (it asked the cloud AI).
    func testAJobPageThatSaysTheJobIsGone() async throws {
        for words in ["The job you are searching for is not available.", "This position is no longer available.",
                      "Applications for this position are no longer being accepted."] {
            try await web.loadTestHTML("<body><nav><a href='/'>Careers home</a></nav><main><p>\(words)</p><p>Find more jobs to match your strengths.</p></main></body>",
                                       base: URL(string: "https://careers.example.test/job/123")!)
            let kind = await web.pageKind().kind
            XCTAssertEqual(kind, .closed, words)
        }
    }

    /// SmartRecruiters' "Pick a date" keeps dates as 2022-03-01 and reads "03/01/2022" as January 2022: the date is
    /// written again its way.
    func testADatePickerThatWantsISODates() async throws {
        try await web.loadTestHTML("""
            <body><form><label for="from">From</label><input id="from" placeholder="Pick a date" required></form>
            <script>
            const box = document.getElementById('from');
            box.addEventListener('blur', () => {
              const v = box.value;
              if (/^\\d{4}-\\d{2}-\\d{2}$/.test(v)) return;
              const y = (v.match(/\\d{4}/) || [''])[0];
              box.value = y ? y + '-01-01' : '';
            });
            </script></body>
            """, base: URL(string: "https://jobs.example.test/apply")!)
        let fields = await web.extractFields(root: nil, exclude: ApplicationHandler.exclude)
        XCTAssertEqual(fields.map(\.spec.label), ["From"])
        let ok = await web.fill(fields[0], "03/01/2022")
        XCTAssertTrue(ok)
        let value = try await page("document.getElementById('from').value") as? String
        XCTAssertEqual(value, "2022-03-01")
        XCTAssertEqual(WebAgent.isoDate("15/03/2022", dayFirst: true), "2022-03-15")
        XCTAssertEqual(WebAgent.isoDate("03/2022", dayFirst: false), "2022-03-01")
        XCTAssertNil(WebAgent.isoDate("March 2022", dayFirst: false))
    }

    /// Workable's start date (react-datepicker): a date set any other way than typing is emptied when the box loses
    /// the focus, so it's typed.
    func testADatePickerThatKeepsOnlyTypedDates() async throws {
        try await web.loadTestHTML("""
            <body><form><label for="d">Please state your earliest start date:</label>
            <div class="react-datepicker__input-container"><input id="d" placeholder="MM/DD/YYYY" inputmode="tel" required></div>
            <div id="cal" hidden>November 2026</div></form>
            <script>
            const box = document.getElementById('d'), cal = document.getElementById('cal');
            let set = false;
            box.addEventListener('focus', () => { cal.hidden = false; });
            box.addEventListener('input', e => { set = !e.isTrusted; });
            box.addEventListener('keydown', e => { if (e.key === 'Tab') cal.hidden = true; });
            box.addEventListener('blur', () => { if (set) box.value = ''; });
            </script></body>
            """, base: URL(string: "https://apply.example.test/acme/j/1/apply/")!)
        let fields = await web.extractFields(root: nil, exclude: ApplicationHandler.exclude)
        let ok = await web.fill(fields[0], "11/30/2026")
        XCTAssertTrue(ok)
        let value = try await page("document.getElementById('d').value") as? String
        XCTAssertEqual(value, "11/30/2026")
        let open = try await page("!document.getElementById('cal').hidden") as? Bool
        XCTAssertEqual(open, false)
    }

    /// Lever's "Current location" keeps only a place picked from what it suggests under the box as it's typed (it's
    /// emptied otherwise): the answer typed and "Austin, TX, USA" picked, not "Austin, MN, USA", nor the help line
    /// below it that was there before typing.
    func testABoxThatKeepsOnlyAPickedSuggestion() async throws {
        try await web.loadTestHTML("""
            <body><form><label><div class="application-label">Current location ✱</div><div class="application-field">
              <input id="loc" name="location" required><input type="hidden" id="sel" name="selectedLocation">
              <div id="dd" style="display:none"></div></div></label>
              <p>Austin, TX office hours: 9–5</p></form>
            <script>
            const box = document.getElementById('loc'), dd = document.getElementById('dd'), sel = document.getElementById('sel');
            const places = ['Austin, MN, USA', 'Austin, TX, USA', 'Boston, MA, USA'];
            let picked = false;
            box.addEventListener('input', () => {
              picked = false; sel.value = '';
              const q = box.value.split(',')[0].trim().toLowerCase(); dd.innerHTML = '';
              setTimeout(() => {
                for (const p of places.filter(p => q && p.toLowerCase().startsWith(q))) {
                  const d = document.createElement('div'); d.className = 'dropdown-location'; d.textContent = p;
                  d.addEventListener('click', () => { box.value = p; sel.value = p; picked = true; dd.style.display = 'none'; });
                  dd.appendChild(d);
                }
                dd.style.display = dd.children.length ? 'block' : 'none';
              }, 150);
            });
            box.addEventListener('blur', () => { if (!picked) box.value = ''; });
            </script></body>
            """, base: URL(string: "https://jobs.lever.example.test/acme/1/apply")!)
        let fields = await web.extractFields(root: nil, exclude: ApplicationHandler.exclude)
        XCTAssertEqual(fields.map(\.spec.label), ["Current location ✱"])
        let ok = await web.fill(fields[0], "Austin, TX")
        XCTAssertTrue(ok)
        let value = try await page("document.getElementById('loc').value + ' | ' + document.getElementById('sel').value") as? String
        XCTAssertEqual(value, "Austin, TX, USA | Austin, TX, USA")
    }

    /// Zoho's "State/Province": a div role=combobox drawn around its own text box, whose search finds nothing for "TX"
    /// but has "Texas". The text box is part of the list, not a question of its own.
    func testAListWithItsOwnTypingBoxInside() async throws {
        try await web.loadTestHTML("""
            <body><form><div class="crc-form-row"><label class="crm-from-label"><span>State/Province</span></label>
              <div class="crc-form-field"><div class="lyteDummyEventContainer" role="combobox" aria-haspopup="listbox" aria-expanded="false" aria-controls="b2" tabindex="-1">
                <input type="text" id="st" autocomplete="off" pattern=".+"></div>
              <div role="listbox" id="b2" style="display:none"></div></div></div></form>
            <script>
            const box = document.getElementById('st'), list = document.getElementById('b2'), wrap = box.parentElement;
            const states = ['Tennessee', 'Texas', 'Utah'];
            box.addEventListener('input', () => {
              const q = box.value.trim().toLowerCase(); list.innerHTML = '';
              setTimeout(() => {
                for (const n of states.filter(n => q.length > 2 && n.toLowerCase().startsWith(q))) {
                  const o = document.createElement('div'); o.setAttribute('role', 'option'); o.textContent = n;
                  o.addEventListener('click', () => { box.value = n; list.style.display = 'none'; wrap.setAttribute('aria-expanded', 'false'); });
                  list.appendChild(o);
                }
                list.style.display = list.children.length ? 'block' : 'none'; wrap.setAttribute('aria-expanded', String(!!list.children.length));
              }, 150);
            });
            </script></body>
            """, base: URL(string: "https://acme.zohorecruit.test/jobs/Careers/1/apply")!)
        let fields = await web.extractFields(root: nil, exclude: ApplicationHandler.exclude)
        XCTAssertEqual(fields.map(\.spec.label), ["State/Province"])
        let ok = await web.fill(fields[0], "TX")
        XCTAssertTrue(ok)
        let value = try await page("document.getElementById('st').value") as? String
        XCTAssertEqual(value, "Texas")
    }

    /// Mastercard's apply page before its form loads: "Get notified for similar jobs" (an email box and Submit) and
    /// "Save job" boxes under "Similar Jobs" are sign-ups, not the application. An application's own email box beside
    /// a talent-community box is still read.
    func testAJobAlertSignUpIsNotTheApplication() async throws {
        try await web.loadTestHTML("""
            <body><main><h1>Software Engineer II</h1><div class="job-actions"><label><input type="checkbox"> Save job Software Engineer II</label></div>
            <div class="alerts"><h3>Get notified for similar jobs</h3><p>With your permission, we will use your email address to send you personalized job alerts.</p>
              <form><label for="ae">Enter Email address (Required)</label><input id="ae" type="email" required><button>Submit</button></form></div>
            <section><h3>Similar Jobs</h3><div><a href="#">Senior Software Engineer</a><label><input type="checkbox"> Save job</label></div></section>
            </main></body>
            """, base: URL(string: "https://careers.example.test/us/en/apply?jobSeqNo=1")!)
        let none = await web.extractFields(root: nil, exclude: ApplicationHandler.exclude)
        XCTAssertEqual(none.map(\.spec.label), [])

        // PG&E's home page, where its "Apply now" led: a job-alert form with four boxes is a sign-up too.
        try await web.loadTestHTML("""
            <body><h1>Working at PG&E</h1><input placeholder="KEYWORD"><input placeholder="LOCATION"><button>Search jobs</button>
            <form action="/form/submit"><div><h2>Sign Up for Job Alerts</h2><p>Don't see what you're looking for? Sign up and we'll notify you.</p></div>
              <label for="f">FIRST NAME</label><input id="f"><label for="l">LAST NAME</label><input id="l">
              <label for="e">EMAIL ADDRESS*</label><input id="e" type="email" required>
              <label for="c">CATEGORY*</label><select id="c" required><option value="">Select a Category</option><option>Engineering / Science</option></select>
              <label for="lo">LOCATION*</label><input id="lo" class="keyword-location" required><button>Add</button><button type="submit">Sign Up</button></form></body>
            """, base: URL(string: "https://jobs.example.test/")!)
        let alerts = await web.extractFields(root: nil, exclude: ApplicationHandler.exclude)
        XCTAssertFalse(alerts.contains { ["FIRST NAME", "EMAIL ADDRESS*", "CATEGORY*", "LOCATION*"].contains($0.spec.label) }, "\(alerts.map(\.spec.label))")

        try await web.loadTestHTML("""
            <body><form><label for="fn">First Name</label><input id="fn" required>
            <label for="ln">Last Name</label><input id="ln" required>
            <div><label for="em">Email</label><input id="em" type="email" required>
              <label><input type="checkbox"> Yes, please also add me to the Talent Community</label></div>
            <button type="submit">Next</button></form></body>
            """, base: URL(string: "https://careers.example.test/us/en/apply?jobSeqNo=1")!)
        let fields = await web.extractFields(root: nil, exclude: ApplicationHandler.exclude)
        XCTAssertEqual(fields.map(\.spec.label), ["First Name", "Last Name", "Email", "Yes, please also add me to the Talent Community"],
                       "the form's own boxes, its sign-up box too (which is left unticked)")
    }

    /// Jobvite (CMG): the application first asks where the person lives, and shows the rest of the form, with its
    /// own button, a moment after that's answered.
    func testAnAnswerThatBringsTheRestOfTheForm() async throws {
        try await web.loadTestHTML("""
            <body><form onsubmit="window.__sent = true; return false"><h2>Data Consent</h2>
            <label for="loc">Location of Residence and Language:</label>
            <select id="loc" required onchange="setTimeout(() => document.getElementById('rest').style.display = 'block', 600)">
              <option value="">Select your location of residence and language</option><option>Non-California</option><option>California</option></select>
            <div id="rest" style="display:none"><label for="fn">First Name (Legal)*</label><input id="fn" required>
              <label for="ln">Last Name (Legal)*</label><input id="ln" required>
              <button type="submit">Submit Application</button></div>
            </form><a href="#">Back</a></body>
            """, base: URL(string: "https://jobs.jobvite.test/acme/job/1/apply")!)
        let model = FakeModel(["Location of Residence and Language:": ("Non-California", .high)])
        let result = try await GenericHandler(web: web, ctx: context(model, practice: true)).apply()
        XCTAssertEqual(result.status, .practiceComplete, "\(result.notes) | \(steps.joined(separator: " | "))")
        let first = try await page("document.getElementById('fn').value") as? String
        XCTAssertEqual(first, "Jane")
    }

    /// Dover (Material UI): each box's words sit in a <div> above it and a hidden legend beside it holds a zero-width
    /// space; the resume drop zone that fills the form comes first, above "First Name *".
    func testBoxesNamedByTheWordsAboveThem() async throws {
        try await web.loadTestHTML("""
            <body><form><div class="zone"><div><div>Autofill from resume</div><div>Drag &amp; drop or upload to autofill your application.</div>
              <button type="button">Upload file</button><input type="file" style="display:none"></div></div>
            <div><div><div class="MuiFormLabel-root">First Name *</div><div><div><input name="firstName" required type="text">
              <fieldset aria-hidden="true"><legend><span>\u{200B}</span></legend></fieldset></div></div></div>
            <div><div class="MuiFormLabel-root">Last Name *</div><div><div><input name="lastName" required type="text">
              <fieldset aria-hidden="true"><legend><span>\u{200B}</span></legend></fieldset></div></div></div></div>
            <button type="submit">Apply</button></form></body>
            """, base: URL(string: "https://app.dover.test/apply/acme/1")!)
        let fields = await web.extractFields(root: nil, exclude: ApplicationHandler.exclude)
        XCTAssertEqual(fields.map(\.spec.label), ["Autofill from resume Drag & drop or upload to autofill your application. Upload file", "First Name *", "Last Name *"])
        XCTAssertEqual(fields.map(\.spec.required), [false, true, true])
    }

    /// Phenom's experience step sits in one part named "workAndEducation": its "Work Experience" and "Education"
    /// headings say which boxes are which.
    func testSectionsInsideAPartNamedForBoth() async throws {
        try await web.loadTestHTML("""
            <body><form><div class="workAndEducation" data-ph-at-id="workAndEducation">
            <section><h3>Work Experience</h3>
              <div><label for="t">Job Title</label><input id="t"></div>
              <div><label for="l">Location</label><input id="l"></div>
              <div><label><input type="checkbox" id="cur"> I currently work here</label></div></section>
            <section><h3>Education</h3>
              <div><label for="s">School or University</label><input id="s"></div>
              <div><label for="sl">Location</label><input id="sl"></div></section>
            </div><button type="submit">Next</button></form></body>
            """, base: URL(string: "https://careers.example.test/us/en/apply?step=2")!)
        let fields = await web.extractFields(root: nil, exclude: ApplicationHandler.exclude)
        XCTAssertEqual(fields.map { "\($0.spec.section) › \($0.spec.label)" }, [
            "Work experience › Job Title", "Work experience › Location", "Work experience › I currently work here",
            "Education › School or University", "Education › Location",
        ])
    }

    /// ADP's, Avaya's and Blue Yonder's job pages: nothing asked yet (Avaya's "how often to receive an alert" box and Blue
    /// Yonder's "Get notified" email box and Submit belong to their job alerts), and buttons that only say "Apply" (ADP's
    /// opens a second "Apply"). They open the application; the practice run doesn't stop at them.
    func testAnApplyButtonBeforeAnyQuestionOpensTheApplication() async throws {
        let html = """
            <body><main><h1>Software Engineer</h1>
            <div class="alerts"><label for="freq">Select how often (in days) to receive an alert:</label><input id="freq" value="7">
              <button type="button">Create Alert</button></div>
            <div class="phenom"><h3>Get notified for similar jobs</h3><label for="ae">Enter Email address</label><input id="ae" type="email">
              <button type="button" onclick="window.__alert = true">Submit</button></div>
            <p>We are hiring a software engineer to build things.</p>
            <button type="button" id="apply" onclick="document.getElementById('how').style.display='block'; this.remove()">Apply</button>
            <div id="how" style="display:none"><p>How would you like to apply?</p>
              <button type="button" onclick="document.getElementById('app').style.display='block'; this.parentNode.remove()">Apply</button></div>
            <form id="app" style="display:none" onsubmit="window.__sent = true; return false">
              <label for="fn">First Name</label><input id="fn" required>
              <label for="ln">Last Name</label><input id="ln" required>
              <label for="em">Email</label><input id="em" type="email" required>
              <button type="submit">Submit Application</button></form>
            </main></body>
            """
        try await web.loadTestHTML(html, base: URL(string: "https://careers.example.test/job/1")!)
        let alerts = await web.extractFields(root: nil, exclude: ApplicationHandler.exclude)
        XCTAssertEqual(alerts.map(\.spec.label), [], "the job alert's box isn't the application")
        let result = try await GenericHandler(web: web, ctx: context(FakeModel(), practice: true)).apply()
        XCTAssertEqual(result.status, .practiceComplete, "\(result.notes) | \(steps.joined(separator: " | "))")
        let first = try await page("document.getElementById('fn').value") as? String
        XCTAssertEqual(first, "Jane", "stopped at the application's own Submit, not at Apply")
        let sent = try await page("window.__sent === true || window.__alert === true") as? Bool
        XCTAssertEqual(sent, false)

        // An "Apply" that leads nowhere is not a finished practice run.
        try await web.loadTestHTML("""
            <body><main><h1>Software Engineer</h1><p>We are hiring.</p><button type="button">Apply</button></main></body>
            """, base: URL(string: "https://careers.example.test/job/2")!)
        let stuck = try await GenericHandler(web: web, ctx: context(FakeModel(), practice: true)).apply()
        XCTAssertNotEqual(stuck.status, .practiceComplete, stuck.notes)
    }

    /// Jobvite keeps its resume box hidden in a popup that "Select" opens ("Dropbox | File | Type or Paste Resume");
    /// the cover letter's is hidden the same way. The resume goes in the resume's box, once.
    func testAResumeBoxThePageKeepsHidden() async throws {
        try await web.loadTestHTML("""
            <body><form>
            <div class="section"><span>Add Resume*</span> <button type="button">Select</button><span id="shown-file"></span></div>
            <label for="fn">First Name</label><input id="fn" required>
            <button type="submit">Next</button></form>
            <div class="jv-add-attachment" style="display:none"><div><input type="file" id="file-input-0">File</div><span>Type or Paste Resume</span></div>
            <div class="jv-add-attachment" style="display:none"><div><input type="file" id="file-input-1">File</div><span>Type or Paste Cover Letter</span></div>
            <script>
            for (const id of ['file-input-0', 'file-input-1']) document.getElementById(id).addEventListener('change', e => {
              window.__files = (window.__files || []).concat([id + ':' + e.target.files[0].name]);
              if (id === 'file-input-0') document.getElementById('shown-file').textContent = e.target.files[0].name + ' remove';
              e.target.value = '';
            });
            </script></body>
            """, base: URL(string: "https://jobs.jobvite.test/acme/job/1/apply")!)
        let home = try TestHome()
        let resume = home.paths.resumeFile
        try Data("%PDF-1.4".utf8).write(to: resume)
        let first = await web.attachToHiddenResumeBox(resume)
        XCTAssertTrue(first)
        let again = await web.attachToHiddenResumeBox(resume)
        XCTAssertFalse(again, "the page shows the file now")
        let files = try await page("(window.__files || []).join(',')") as? String
        XCTAssertEqual(files, "file-input-0:\(resume.lastPathComponent)")
    }

    /// Workday's lists (Broadcom once the country was the United States): one says it's open for a moment after Escape
    /// closed it, and the phone code's chosen "United States of America (+1)" sits in a list that's always shown.
    /// Neither list is left open, and each box reads and takes its own choices.
    func testWorkdayListsThatCloseSlowly() async throws {
        try await web.loadTestHTML("""
            <body><form>
            <div data-automation-id="formField-source"><label for="source--source">How Did You Hear About Us?</label>
              <button type="button" id="source--source" aria-haspopup="listbox" aria-expanded="false">Select One</button></div>
            <div data-automation-id="formField-countryPhoneCode"><label for="pc">Country Phone Code</label>
              <ul role="listbox" data-automation-id="selectedItemList"><li role="presentation"><div role="option">United States of America (+1)</div></li></ul>
              <input id="pc" type="text"></div>
            <div data-automation-id="formField-phoneType"><label for="phoneNumber--phoneType">Phone Device Type</label>
              <button type="button" id="phoneNumber--phoneType" aria-haspopup="listbox" aria-expanded="false">Select One</button></div>
            </form>
            <script>
            const lists = {'source--source': ['LinkedIn', 'Indeed.com', 'Employee'], 'phoneNumber--phoneType': ['Fax', 'Mobile', 'Pager']};
            let open = null;
            const close = b => { if (open) { open.remove(); open = null; } b.setAttribute('aria-expanded', 'false'); };
            for (const id of Object.keys(lists)) {
              const b = document.getElementById(id);
              b.addEventListener('click', () => {
                // Whether the list is open by its own reckoning, not by what it says.
                if (open && open.__for === b) { close(b); return; }
                const ul = document.createElement('ul'); ul.setAttribute('role', 'listbox');
                const r = b.getBoundingClientRect();
                ul.style.cssText = 'position:absolute;left:' + r.left + 'px;top:' + (r.bottom + scrollY) + 'px;background:#fff;margin:0;padding:0;z-index:9';
                for (const o of lists[id]) {
                  const li = document.createElement('li'); li.setAttribute('role', 'option'); li.textContent = o;
                  li.addEventListener('click', () => { b.textContent = o; close(b); });
                  ul.appendChild(li);
                }
                if (open) open.remove();
                ul.__for = b; document.body.appendChild(ul); open = ul; b.setAttribute('aria-expanded', 'true');
              });
            }
            // Escape hides the list at once but says so a moment later.
            document.addEventListener('keydown', e => {
              if (e.key !== 'Escape' || !open) return;
              const b = document.querySelector('[aria-expanded=true]');
              open.remove(); open = null;
              setTimeout(() => b && b.setAttribute('aria-expanded', 'false'), 150);
            }, true);
            </script></body>
            """, base: URL(string: "https://example.wd1.myworkdayjobs.com/en-US/External/apply")!)
        let fields = await web.extractFields(root: nil, exclude: ApplicationHandler.exclude).filter { $0.kind == .combobox }
        XCTAssertEqual(fields.map(\.spec.label), ["How Did You Hear About Us?", "Phone Device Type"])
        XCTAssertEqual(fields.map(\.spec.options), [["LinkedIn", "Indeed.com", "Employee"], ["Fax", "Mobile", "Pager"]])
        try await web.sleep(0.3)
        let stillOpen = try await page("document.querySelectorAll('[aria-expanded=true]').length") as? Int
        XCTAssertEqual(stillOpen, 0)
        let source = await web.fill(fields[0], "LinkedIn"), phone = await web.fill(fields[1], "Mobile")
        XCTAssertTrue(source)
        XCTAssertTrue(phone)
        let shown = try await page("[...document.querySelectorAll('button')].map(b => b.textContent).join(',')") as? String
        XCTAssertEqual(shown, "LinkedIn,Mobile")
    }
}
