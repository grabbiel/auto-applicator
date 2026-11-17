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
                 profile: Profile = Fixture.profile) -> ApplyContext {
        let ai = AIService(model: model)
        var settings = Store(paths: home.paths).loadSettings()
        settings.practiceMode = practice
        return ApplyContext(jobID: "4242", job: Fixture.job, settings: settings, paths: home.paths, profile: profile, db: home.db,
                            answerer: Answerer(profile: profile, db: home.db, ai: ai), ai: ai,
                            verifier: verifier ?? EmailVerifier(secrets: Secrets(), ai: nil), secrets: secrets, practice: practice) { [weak self] in
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

