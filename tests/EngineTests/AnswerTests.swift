import XCTest
@testable import Engine

final class AnswerTests: XCTestCase {
    let profile = Fixture.profile

    func testMatchOptionVariants() {
        XCTAssertEqual(matchOption("Yes", ["Yes, I am authorized to work in the US", "No, I am not"]), "Yes, I am authorized to work in the US")
        XCTAssertEqual(matchOption("decline to self-identify", ["Male", "Female", "I don't wish to answer"]), "I don't wish to answer")
        XCTAssertEqual(matchOption("united states", ["Canada", "United States", "Mexico"]), "United States")
        XCTAssertNil(matchOption("Purple", ["Red", "Blue"]))
        XCTAssertEqual(matchOption("No", ["Select...", "Yes", "No"]), "No")
    }

    func testNumericRanges() {
        let opts = ["0-1 years", "2-4 years", "5-7 years", "8+ years"]
        XCTAssertEqual(matchNumericRange("6", opts), "5-7 years")
        XCTAssertEqual(matchNumericRange("9", opts), "8+ years")
        XCTAssertEqual(matchNumericRange("0", ["Less than 1 year", "1-3 years"]), "Less than 1 year")
        XCTAssertNil(matchNumericRange("six", opts))
    }

    func testCoerceAnswer() {
        XCTAssertEqual(coerceAnswer(field("Years", .number), "About 3 years"), "3")
        XCTAssertNil(coerceAnswer(field("Years", .number), "none"))
        XCTAssertEqual(coerceAnswer(field("Agree", .checkbox), "I agree"), "Yes")
        XCTAssertEqual(coerceAnswer(field("Langs", .checkboxGroup, ["Python", "Go", "Rust"]), "python ; Rust ; COBOL"), "Python ; Rust")
        XCTAssertEqual(coerceAnswer(field("Why", .textarea, maxLength: 12), "Because I love building things"), "Because I")
        XCTAssertNil(coerceAnswer(field("Email", .email), "not-an-email"))
    }

    func testProfileRules() {
        func rule(_ f: FieldSpec) -> String? { ProfileRules.answer(profile, f) }
        XCTAssertEqual(rule(field("First Name")), "Jane")
        XCTAssertEqual(rule(field("Legal last name *")), "Doe")
        XCTAssertEqual(rule(field("Email address")), "jane.doe@example.com")
        XCTAssertEqual(rule(field("Will you now or in the future require visa sponsorship?", .radio, ["Yes", "No"])), "No")
        XCTAssertEqual(rule(field("Are you legally authorized to work in the United States?")), "Yes")
        XCTAssertEqual(rule(field("How many years of experience do you have with Python?", .number)), "6")
        XCTAssertEqual(rule(field("How many years of work experience do you have with Kubernetes?", .number)), "2")
        XCTAssertEqual(rule(field("How many years of professional experience do you have?", .number)), "6")
        XCTAssertNil(rule(field("How many years of experience do you have with Rust?", .number)))
        XCTAssertEqual(rule(field("Gender", .select, ["Male", "Female", "Decline"])), "Decline to self-identify")
        XCTAssertEqual(rule(field("Phone device type", .select, ["Mobile", "Home"])), "Mobile")
        XCTAssertNil(rule(field("Describe your Python experience", .textarea)))
        XCTAssertEqual(rule(field("Are you comfortable working in a fast-paced environment?")), "Yes")
        // a rule that matches but has no data doesn't fall through to a broader one
        XCTAssertEqual(rule(field("Portfolio URL")), "https://github.com/janedoe")
    }

    /// Version 0.3 answered "years of C" questions with the years for C++ or C# (substring match).
    func testSkillYearsMatchWholeTokens() {
        var p = profile
        p.experienceYears = ["C": 1, "C++": 7, "Go": 3]
        XCTAssertEqual(ProfileRules.answer(p, field("How many years of C++ experience do you have?", .number)), "7")
        XCTAssertEqual(ProfileRules.answer(p, field("Years of experience with C?", .number)), "1")
        XCTAssertNil(ProfileRules.answer(p, field("How many years of C# experience?", .number)))
        XCTAssertEqual(ProfileRules.answer(p, field("Years with Go", .number)), "3")
        XCTAssertNil(ProfileRules.answer(p, field("Years with Google Cloud", .number)))
    }

    /// Version 0.3 treated every question as "years of a skill", so commute or notice questions were never answered.
    func testYearsOfSkillDetection() {
        XCTAssertTrue(asksYearsOfSkill(field("How many years of experience do you have with Rust?", .number)))
        XCTAssertTrue(asksYearsOfSkill(field("Years of Terraform experience", .number)))
        XCTAssertFalse(asksYearsOfSkill(field("How long is your commute in minutes?", .number)))
        XCTAssertFalse(asksYearsOfSkill(field("How many weeks of notice do you need?", .number)))
        XCTAssertFalse(asksYearsOfSkill(field("What is your favorite color?")))
        XCTAssertEqual(skillInYearsQuestion("How many years of experience do you have with Rust?"), "Rust")
        XCTAssertEqual(skillInYearsQuestion("Years of professional Terraform experience*"), "Terraform")
        XCTAssertEqual(skillInYearsQuestion("Kubernetes (years)"), "Kubernetes")
    }

    func testQuestionHashMatchesVersion03() {
        // Values computed by version 0.3's question_hash, so answers learned there keep working.
        XCTAssertEqual(questionHash("Are you legally authorized to work in the United States? *", "select", ["Select...", "Yes", "No"]),
                       "88ad0a89d73202c0120784bb98c0275ee168653f65e95e7c47039fb0fc676a5c")
        XCTAssertEqual(questionHash("Ça va? “Quoted” — naïve 😀", "radio", ["Oui", "Non", "Peut-être 😀"]),
                       "450582e054fd5be37a79a3be344ceef003073455308044c4b0b78da5a5b43ced")
    }

    func testResolverOrderAndPolicy() async throws {
        let home = try TestHome()
        let model = FakeModel(["rust": ("1", .low), "favorite color": ("Blue", .medium), "hobbies": ("", .low)])
        let answerer = Answerer(profile: profile, db: home.db, ai: AIService(model: model))
        let cached = field("Do you have a driver's license?", .radio, ["Yes", "No"], id: "f_cache")
        home.db.cachePut(questionHash(cached.label, "radio", cached.options), question: cached.label, fieldType: "radio", options: ["Yes", "No"],
                         answer: "Yes", source: "user")
        let fields = [
            field("First name", id: "f_name"),
            field("Email", id: "f_prefilled", current: "already@there.com"),
            cached,
            field("Years of experience with Rust", .number, id: "f_rust"),
            field("Favorite color", .select, ["Red", "Blue"], id: "f_color"),
            field("Hobbies", required: false, id: "f_hobby"),
            field("Resume", .file, id: "f_file"),
        ]
        let res = await answerer.resolve(fields, job: Fixture.job)
        XCTAssertEqual(res.answers, ["f_name": "Jane", "f_prefilled": "jane.doe@example.com", "f_cache": "Yes", "f_color": "Blue"],
                       "the person's own email replaces another one the site put in")
        XCTAssertEqual(res.sources, ["f_name": "profile", "f_prefilled": "profile", "f_cache": "cache", "f_color": "llm:medium"])
        XCTAssertEqual(res.unresolved.map(\.id), ["f_rust"])
        XCTAssertEqual(res.leftBlank.map(\.id), ["f_hobby"])
        XCTAssertTrue(res.blocked)
        XCTAssertEqual(model.calls.first, ["Favorite color", "Hobbies"], "years of Rust is never guessed by the AI")
        XCTAssertEqual(home.db.cacheGet(questionHash("Favorite color", "select", ["Red", "Blue"])), "Blue")
        answerer.flagUnresolved(res, jobID: "job-1", company: "Initech")
        XCTAssertEqual(home.db.listPending().first?.question, "Years of experience with Rust")
    }

    func testFeedbackBypassesCache() async throws {
        let home = try TestHome()
        let model = FakeModel(feedback: ["start": ("2026-12-01", .high)])
        let answerer = Answerer(profile: profile, db: home.db, ai: AIService(model: model))
        let f = field("Desired start", id: "f1", current: "next week")
        let qh = questionHash(f.label, "text", [])
        home.db.cachePut(qh, question: f.label, fieldType: "text", options: [], answer: "next week", source: "llm:medium")
        model.evidence = "earliest_start: 2 weeks after offer 2026-12-01"
        let res = await answerer.resolve([f], job: Fixture.job, feedback: ["f1": "Use YYYY-MM-DD"])
        XCTAssertEqual(res.answers, ["f1": "2026-12-01"])
        XCTAssertEqual(model.feedback.first, ["Desired start"])
        XCTAssertEqual(home.db.cacheGet(qh), "2026-12-01")

        let blank = field("First name", id: "f2")
        let res2 = await answerer.resolve([blank], job: Fixture.job, feedback: ["f2": "This field is required"])
        XCTAssertEqual(res2.answers, ["f2": "Jane"])
        XCTAssertEqual(res2.sources, ["f2": "profile"])
    }

    func testCompanySpecificQuestionsNotCached() async throws {
        let home = try TestHome()
        let answerer = Answerer(profile: profile, db: home.db, ai: AIService(model: FakeModel(["initech": ("Yes", .high)])))
        _ = await answerer.resolve([field("Have you worked at Initech before?", .radio, ["Yes", "No"])], job: Fixture.job)
        XCTAssertTrue(home.db.cacheEntries().isEmpty)
    }

    func testGrounding() {
        let corpus = contentTokens("experience_years:\n  Python: 6\nwork_authorization:\n  requires_sponsorship: false\n")
        XCTAssertTrue(Answerer.isGrounded(field("Sponsorship?", .radio, ["Yes", "No"]), "No", "requires_sponsorship: false", corpus))
        XCTAssertFalse(Answerer.isGrounded(field("Felony?", .radio, ["Yes", "No"]), "No", "", corpus))
        XCTAssertFalse(Answerer.isGrounded(field("Felony?", .radio, ["Yes", "No"]), "No", "No criminal record mentioned", corpus))
        XCTAssertTrue(Answerer.isGrounded(field("Python years", .number), "6", "Python: 6", corpus))
        XCTAssertFalse(Answerer.isGrounded(field("Rate Python 1-10", .number), "9", "Python: 6", corpus))
    }

    func testUngroundedAnswersAreParked() async throws {
        let home = try TestHome()
        let model = FakeModel(["felony": ("No", .high)])
        model.evidence = "No criminal history mentioned"
        let res = await Answerer(profile: profile, db: home.db, ai: AIService(model: model))
            .resolve([field("Have you ever been convicted of a felony?", .radio, ["Yes", "No"])], job: Fixture.job)
        XCTAssertTrue(res.blocked)
        XCTAssertTrue(res.answers.isEmpty)
    }

    func testSensitiveQuestionsNeverGuessed() async throws {
        let home = try TestHome()
        let model = FakeModel(default: ("No", .high))
        let fields = [field("Have you ever been convicted of a felony?", .radio, ["Yes", "No"], id: "a"),
                      field("Rate your Python proficiency (1-10)", .number, id: "b"),
                      field("What is your current salary?", required: false, id: "c")]
        let res = await Answerer(profile: profile, db: home.db, ai: AIService(model: model)).resolve(fields, job: Fixture.job)
        XCTAssertEqual(res.unresolved.map(\.id), ["a", "b"])
        XCTAssertEqual(res.leftBlank.map(\.id), ["c"])
        XCTAssertTrue(model.calls.isEmpty)
        home.db.cachePut(questionHash(fields[0].label, "radio", ["Yes", "No"]), question: fields[0].label, fieldType: "radio",
                         options: ["Yes", "No"], answer: "No", source: "user")
        let again = await Answerer(profile: profile, db: home.db, ai: AIService(model: model)).resolve(Array(fields.prefix(1)), job: Fixture.job)
        XCTAssertEqual(again.answers, ["a": "No"])
    }

    /// Answers the user gave teach the app: a question worded almost the same reuses the answer.
    func testMemoryReusesSimilarQuestions() async throws {
        let home = try TestHome()
        home.db.cachePut(questionHash("Do you have a valid driver's license?", "radio", ["Yes", "No"]),
                         question: "Do you have a valid driver's license?", fieldType: "radio", options: ["Yes", "No"], answer: "Yes", source: "user")
        let model = FakeModel()
        let answerer = Answerer(profile: profile, db: home.db, ai: AIService(model: model))
        let res = await answerer.resolve([field("Do you have a valid drivers license?", .select, ["Select", "Yes", "No"], id: "x")], job: Fixture.job)
        XCTAssertEqual(res.answers, ["x": "Yes"])
        XCTAssertEqual(res.sources, ["x": "memory"])
        XCTAssertTrue(model.calls.isEmpty)
        // a different question isn't matched
        XCTAssertNil(answerer.memory.similarAnswer(for: field("Do you have a valid passport?", .radio, ["Yes", "No"])))
    }

    func testFactsReachTheAI() async throws {
        let home = try TestHome()
        _ = home.db.addFact("I have a valid commercial driver's license (class A).")
        let memory = Memory(db: home.db)
        let relevant = memory.relevant(for: [field("Do you hold a commercial driver's license?", .radio, ["Yes", "No"])], limit: 3)
        XCTAssertEqual(relevant.first, "Fact: I have a valid commercial driver's license (class A).")
        XCTAssertTrue(memory.relevant(for: [field("What is your favorite programming language?")], limit: 3).isEmpty)
    }

    func testLearnedSkillFromAnswer() {
        XCTAssertEqual(Memory.learnedSkill(question: "How many years of experience do you have with Rust?", answer: "3")?.skill, "Rust")
        XCTAssertEqual(Memory.learnedSkill(question: "How many years of experience do you have with Rust?", answer: "3")?.years, 3)
        XCTAssertNil(Memory.learnedSkill(question: "What is your favorite color?", answer: "3"))
    }

    func testCompactModelsGetSmallerBatches() async throws {
        let model = FakeModel()
        model.compact = true
        XCTAssertEqual(AIService(model: model).batchSize, 3)
        model.compact = false
        XCTAssertEqual(AIService(model: model).batchSize, 6)
    }

    func testKnowledgeReportScore() {
        let empty = KnowledgeReport(profile: Profile(), resumePresent: false, emailConfigured: false, learnedAnswers: 0, facts: 0, pending: 0)
        XCTAssertEqual(empty.score, 0, accuracy: 0.001)
        let full = KnowledgeReport(profile: profile, resumePresent: true, emailConfigured: true, learnedAnswers: 12, facts: 4, pending: 0)
        XCTAssertGreaterThan(full.score, 0.8)
        XCTAssertFalse(full.suggestions.contains { $0.id == "resume" || $0.id == "contact" })
        XCTAssertEqual(empty.suggestions.first?.id, "resume")
    }

    // MARK: sections, plausibility, consent, topics

    func testSectionTellsWhichDateAQuestionMeans() async throws {
        let home = try TestHome()
        let answerer = Answerer(profile: profile, db: home.db, ai: nil)
        let months = ["Select", "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        let end = FieldSpec(id: "a", label: "End date year", required: true, section: "EDUCATION")
        XCTAssertEqual(end.contextLabel, "Education › End date year")
        let schoolStart = FieldSpec(id: "b", label: "Start date month", type: .select, options: months, required: true, section: "Your education")
        let workStart = FieldSpec(id: "c", label: "Start date month", type: .select, options: months, required: true, section: "Employment History")
        let reference = FieldSpec(id: "d", label: "Phone", required: true, section: "Professional References")
        let plain = FieldSpec(id: "e", label: "City", required: true, section: "Senior Software Engineer")
        XCTAssertEqual(plain.section, "", "a job title isn't a section")
        let res = await answerer.resolve([end, schoolStart, workStart, reference, plain], job: Fixture.job)
        XCTAssertEqual(res.answers["a"], "2019")
        XCTAssertEqual(res.answers["b"], "August")
        XCTAssertEqual(res.answers["c"], "March")
        XCTAssertNil(res.answers["d"], "a reference's phone is never the person's own")
        XCTAssertEqual(res.unresolved.map(\.contextLabel), ["References › Phone"])
        XCTAssertEqual(res.answers["e"], "Austin")
    }

    /// TCS: "Title" with Mr./Ms./Dr. is the person's to say (never guessed from a name, never the job title); the
    /// time zone comes from the address; the skills from the profile, those the job mentions first, over an AI guess
    /// saved before (the person's own answer still wins).
    func testTitleTimezoneAndSkillsFromTheProfile() async throws {
        let home = try TestHome()
        let title = field("Title", .combobox, ["Dr.", "Mr.", "Ms."], id: "t")
        let zone = field("Preferred Timezone", .text, id: "z")
        var skills = field("Skills", .text, id: "s")
        skills.maxChoices = 5
        let ai = AIService(model: FakeModel(default: ("Java Developer", .high)))
        home.db.cachePut(Answerer.hash(skills), question: "Skills", fieldType: "text", options: [], answer: "Java (1); C# (1)", source: "llm:high")
        let res = await Answerer(profile: profile, db: home.db, ai: ai).resolve([title, zone, skills], job: Fixture.job)
        XCTAssertEqual(res.unresolved.map(\.id), ["t"], "\(res.answers)")
        XCTAssertEqual(res.answers["z"], "America/Chicago")
        XCTAssertEqual(res.answers["s"], "Python; AWS; SQL; PostgreSQL; Docker")
        var p = profile
        p.eeo.gender = "Male"
        p.personal.address.state = "Oregon"
        let res2 = await Answerer(profile: p, db: home.db, ai: ai).resolve([title, zone], job: Fixture.job)
        XCTAssertEqual(res2.answers["t"], "Mr.")
        XCTAssertEqual(res2.answers["z"], "America/Los_Angeles")
        home.db.cachePut(Answerer.hash(skills), question: "Skills", fieldType: "text", options: [], answer: "Go; Rust", source: "user")
        let res3 = await Answerer(profile: profile, db: home.db, ai: ai).resolve([skills], job: Fixture.job)
        XCTAssertEqual(res3.answers["s"], "Go; Rust")
    }

    /// "How did you hear about us?" without LinkedIn among the choices (Paylocity): the choice for job boards.
    func testHeardOnLinkedInAmongOtherChoices() {
        var p = profile
        p.preferences.howDidYouHear = "LinkedIn"
        let paylocity = ["Online Job Board", "Company Website", "Friend or Family Member", "Current Employee", "Other"]
        XCTAssertEqual(ProfileRules.answer(p, field("How did you hear about us?", .radio, paylocity)), "Online Job Board")
        XCTAssertEqual(ProfileRules.answer(p, field("How did you hear about us?", .select, ["LinkedIn", "Indeed", "Other"])), "LinkedIn")
        XCTAssertEqual(ProfileRules.answer(p, field("How did you hear about us?", .select, ["Employee referral", "Other"])), "Other")
    }

    /// Paylocity read the last name off the resume into "Middle Name": it's emptied; a real-looking one is left alone.
    func testMiddleNameThatIsTheLastNameIsEmptied() async throws {
        let home = try TestHome()
        let res = await Answerer(profile: profile, db: home.db, ai: AIService(model: FakeModel()))
            .resolve([field("Middle Name", required: false, id: "m", current: profile.personal.lastName),
                      field("Middle Initial", required: false, id: "keep", current: "Q")], job: Fixture.job)
        XCTAssertEqual(res.answers["m"], "")
        XCTAssertNil(res.answers["keep"])
    }

    /// The profile has no middle name: "M.I." and "Middle name" are left empty, never guessed (TCS's got the full name).
    /// Links go in with https:// and LinkedIn's own form; another form of the person's link already in the box (read
    /// off the resume) is replaced, and the same link is left alone.
    func testOwnLinksInTheFormEveryFormTakes() async throws {
        var p = profile
        p.personal.linkedin = "linkedin.com/in/janedoe/"
        p.personal.github = "github.com/janedoe"
        let home = try TestHome(profile: p)
        let res = await Answerer(profile: p, db: home.db, ai: AIService(model: FakeModel()))
            .resolve([field("LinkedIn", required: false, id: "li", current: "linkedin.com/in/janedoe"),
                      field("GitHub", required: false, id: "gh"),
                      field("LinkedIn Profile", required: false, id: "same", current: "https://www.linkedin.com/in/janedoe"),
                      field("City", id: "city", current: "Austin, TX")], job: Fixture.job)
        XCTAssertEqual(res.answers["li"], "https://www.linkedin.com/in/janedoe")
        XCTAssertEqual(res.answers["gh"], "https://github.com/janedoe")
        XCTAssertNil(res.answers["same"])
        XCTAssertNil(res.answers["city"], "a box that already has the person's city keeps it")
        XCTAssertEqual(ProfileRules.link("https://pe.linkedin.com/in/jane-doe-123?trk=x"), "https://www.linkedin.com/in/jane-doe-123")
        XCTAssertEqual(ProfileRules.link("http://janedoe.dev"), "http://janedoe.dev")
    }

    /// Questions the profile answers that used to wait for the person: the state under other labels, living in the
    /// United States, and having worked for the company before (from the work history; not relatives who work there).
    func testStateLocationAndFormerEmployerFromTheProfile() async throws {
        var p = profile
        p.personal.address.state = "Oregon"
        p.personal.address.country = "United States"
        for label in ["State / Province", "State Select a state", "State", "State/Province", "Province"] {
            XCTAssertEqual(ProfileRules.answer(p, field(label)), "Oregon", label)
        }
        let yesNo = ["Yes", "No"]
        XCTAssertEqual(ProfileRules.answer(p, field("Are you currently located in the United States?", .radio, yesNo)), "Yes")
        p.personal.address.country = "Peru"
        XCTAssertEqual(ProfileRules.answer(p, field("Are you currently located in the U.S.?", .radio, yesNo)), "No")
        let home = try TestHome(profile: p)
        let answerer = Answerer(profile: p, db: home.db, ai: AIService(model: FakeModel()))
        let booz = JobContext(title: "Software Engineer", company: "Booz Allen Hamilton")
        var res = await answerer.resolve([field("Have you previously been employed by Booz Allen?", .radio, yesNo, id: "b"),
                                          field("Do you have any relatives employed by Booz Allen?", .radio, yesNo, id: "rel")], job: booz)
        XCTAssertEqual(res.answers["b"], "No")
        XCTAssertNotEqual(res.sources["rel"], "profile")
        let comcast = JobContext(title: "Engineer", company: "Comcast")
        let worked = field("Do you currently work or have you previously worked as a full/part time employee or as a contractor of Comcast or any Company within the Comcast Family?", .radio, yesNo, id: "c")
        res = await answerer.resolve([worked], job: comcast)
        XCTAssertEqual(res.answers["c"], "No")
        p.workHistory = [Role(company: "Comcast Cable", title: "Intern")]
        res = await Answerer(profile: p, db: home.db, ai: AIService(model: FakeModel())).resolve([worked], job: comcast)
        XCTAssertEqual(res.answers["c"], "Yes")
    }

    /// A box the form says is empty after the app filled it (the page redrew): the profile's answer again, never a
    /// question for the person; a box that kept a value the form turns away goes to the AI with the error.
    func testEmptiedBoxGetsTheProfileAnswerAgain() async throws {
        let home = try TestHome()
        let ai = AIService(model: FakeModel(default: ("", .low)))
        let res = await Answerer(profile: profile, db: home.db, ai: ai)
            .resolve([field("Mobile Phone", id: "m"), field("Email", id: "e", current: "jane@")], job: Fixture.job,
                     feedback: ["m": "This field is required", "e": "Enter a valid email address"])
        XCTAssertEqual(res.answers["m"], profile.personal.phone)
        XCTAssertTrue(res.unresolved.map(\.id).contains("e") || res.answers["e"] != "jane@", "\(res.answers)")
    }

    /// Blue Yonder read "Peru" off the resume into Country and the old number into Phone Extension, and asked a
    /// former employee's questions: the profile's own details win, an extension and a former employee's details stay
    /// empty, a second last name is never guessed, and "worked for this organization" is answered from the profile.
    func testProfileBeatsWhatTheSiteReadOffTheResume() async throws {
        var p = profile
        p.personal.address.country = "United States"
        p.personal.phone = "5035550100"
        let home = try TestHome(profile: p)
        let ai = AIService(model: FakeModel(default: ("Defined a generic XML schema", .high)))
        let job = JobContext(title: "Software Engineer I", company: "Blue Yonder")
        let countries = ["Peru", "United States", "Canada"]
        let res = await Answerer(profile: p, db: home.db, ai: ai).resolve([
            field("Country", .select, countries, id: "country", current: "Peru"),
            field("Phone Number", .tel, id: "phone", current: "(503) 555-0100"),
            field("Phone Extension", required: false, id: "ext"),
            field("Who was your Manager?", required: false, id: "mgr"),
            field("What was your Employee ID?", required: false, id: "emp"),
            field("Secondary Name", required: false, id: "second"),
            field("Have you previously worked for this organization? If Yes, please answer the questions below.", .radio, ["Yes", "No"], id: "before"),
            field("First Name", id: "fn", current: p.personal.firstName),
        ], job: job)
        XCTAssertEqual(res.answers["country"], "United States")
        XCTAssertNil(res.answers["phone"], "the same number written another way is left alone")
        XCTAssertNil(res.answers["fn"])
        for id in ["ext", "mgr", "emp", "second"] {
            XCTAssertNil(res.answers[id], id)
            XCTAssertTrue(res.leftBlank.map(\.id).contains(id), id)
        }
        XCTAssertEqual(res.answers["before"], "No")
        XCTAssertFalse(Answerer.sameAnswer("US", "Russia"))
        XCTAssertTrue(Answerer.sameAnswer("Oregon", "OR - Oregon"))
    }

    func testDegreeQuestionsFromTheEducation() {
        var p = profile
        p.education = [Education(school: "Nevada State University", degree: "Master’s of Engineering in Computer Science"),
                       Education(school: "St. Joseph’s University", degree: "Bachelor of Arts in Economics")]
        let yesNo = ["Yes", "No"]
        let q = "Do you have a minimum of a Bachelor's degree or foreign equivalent or three years of relevant work experience in lieu of every year of education?"
        XCTAssertEqual(ProfileRules.answer(p, field(q, .radio, yesNo)), "Yes")
        XCTAssertEqual(ProfileRules.answer(p, field("Do you have a Master's degree?", .radio, yesNo)), "Yes")
        XCTAssertEqual(ProfileRules.answer(p, field("Have you completed a PhD degree?", .radio, yesNo)), "No")
        p.education = []
        XCTAssertNil(ProfileRules.answer(p, field(q, .radio, yesNo)))
    }

    func testErrorNoteIsNotPartOfTheQuestion() {
        XCTAssertEqual(WebAgent.withoutErrorNote("Are you currently a student? This field is required", error: ""), "Are you currently a student?")
        XCTAssertEqual(WebAgent.withoutErrorNote("Mobile Phone Please enter a valid phone number", error: "Please enter a valid phone number"), "Mobile Phone")
        XCTAssertEqual(WebAgent.withoutErrorNote("Required field", error: ""), "Required field")
        XCTAssertEqual(WebAgent.withoutErrorNote("City", error: ""), "City")
    }

    func testSchoolUnderOtherNames() {
        for label in ["School", "University name", "School / education institution", "Name of college", "Institution"] {
            XCTAssertEqual(ProfileRules.answer(profile, field(label)), "University of Texas at Austin", label)
        }
        XCTAssertNil(ProfileRules.answer(profile, field("High school diploma")))
    }

    func testMiddleNameIsNeverGuessed() async throws {
        let home = try TestHome()
        let ai = AIService(model: FakeModel(default: ("Jane Doe", .high)))
        let res = await Answerer(profile: profile, db: home.db, ai: ai)
            .resolve([field("M.I.", required: false, id: "mi"), field("Middle name", required: false, id: "mn"), field("First name", id: "fn")], job: Fixture.job)
        XCTAssertEqual(Set(res.leftBlank.map(\.id)), ["mi", "mn"])
        XCTAssertNil(res.answers["mi"])
        XCTAssertNil(res.answers["mn"])
        XCTAssertEqual(res.answers["fn"], profile.personal.firstName)
    }

    /// "I can't answer" (a PAN number for someone who isn't from India): the jobs waiting on it are skipped, and a
    /// later form that requires it skips the job instead of asking again; an optional one is left empty.
    func testQuestionYouCantAnswerSkipsTheJobs() async throws {
        let home = try TestHome()
        let pan = field("PAN Card Number", id: "pan")
        let hash = Answerer.hash(pan)
        home.db.upsertJob("101", status: .needsAnswer, title: "Java developer", company: "Tata Consultancy Services")
        home.db.addPending(hash, question: pan.contextLabel, fieldType: "text", options: [], jobID: "101", company: "Tata Consultancy Services")
        home.db.addPending(Answerer.hash(field("Your PAN Card Number")), question: "Your PAN Card Number", fieldType: "text", options: [], jobID: "102", company: "TCS")
        XCTAssertEqual(home.db.pendingQuestion(company: "tata consultancy services")?.hash, hash)
        XCTAssertNil(home.db.pendingQuestion(company: "Infosys"))

        let declined = QuestionGroups.decline(home.db.listPending().first { $0.hash == hash }!, db: home.db)
        XCTAssertEqual(declined, 2, "the same question in other words goes too")
        XCTAssertTrue(home.db.listPending().isEmpty)
        XCTAssertEqual(home.db.job("101")?.status, .skippedCantAnswer)
        XCTAssertTrue(JobStatus.skippedCantAnswer.isFinal)
        XCTAssertTrue(home.db.answeredJobs().isEmpty, "not retried as if answered")

        let answerer = Answerer(profile: profile, db: home.db, ai: AIService(model: FakeModel()))
        let res = await answerer.resolve([pan, field("PAN Card Number", required: false, id: "opt")], job: Fixture.job)
        XCTAssertEqual(res.declined.map(\.id), ["pan"])
        XCTAssertEqual(res.leftBlank.map(\.id), ["opt"])
        XCTAssertTrue(res.blocked)
        XCTAssertTrue(home.db.listPending().isEmpty, "not asked again")
    }

    /// Answers worked out from the profile go when it changes (an address since corrected); the person's own stay.
    func testChangedProfileForgetsWorkedOutAnswers() throws {
        let home = try TestHome()
        home.db.cachePut("a", question: "Address Line 1", fieldType: "text", options: [], answer: "Lima, Peru", source: "llm:high")
        home.db.cachePut("b", question: "Country", fieldType: "text", options: [], answer: "Peru", source: "profile")
        home.db.cachePut("c", question: "Salary", fieldType: "text", options: [], answer: "90000", source: "user")
        home.db.cachePut("d", question: "PAN", fieldType: "text", options: [], answer: "", source: "declined")
        XCTAssertEqual(home.db.forgetDerivedAnswers(), 2)
        XCTAssertEqual(Set(home.db.cacheEntries().map(\.hash)), ["c", "d"])
        var moved = profile
        XCTAssertEqual(moved.fingerprint, profile.fingerprint)
        moved.personal.address.city = "Denver"
        XCTAssertNotEqual(moved.fingerprint, profile.fingerprint)
        home.db.setMeta("profile", moved.fingerprint)
        XCTAssertEqual(home.db.meta("profile"), moved.fingerprint)
    }

    func testRequiredMarksAreNotShown() {
        XCTAssertEqual(field("*Start year").plainLabel, "Start year")
        XCTAssertEqual(field("GPA *").plainLabel, "GPA")
        XCTAssertEqual(field("Phone (required)").plainLabel, "Phone")
        XCTAssertEqual(field("*").plainLabel, "*")
        var f = field("*Start year")
        f.section = "Work experience"
        XCTAssertEqual(f.contextLabel, "Work experience › Start year")
        XCTAssertEqual(Answerer.hash(field("*GPA")), Answerer.hash(field("GPA")), "answers saved before still match")
    }

    func testDateParts() {
        XCTAssertEqual(ProfileRules.dateParts("2024-2026").startYear, 2024)
        XCTAssertEqual(ProfileRules.dateParts("2024-2026").endYear, 2026)
        XCTAssertNil(ProfileRules.dateParts("2024-2026").month)
        XCTAssertEqual(ProfileRules.dateParts("June 2026").month, 6)
        XCTAssertEqual(ProfileRules.dateParts("2019-05").month, 5)
        XCTAssertEqual(ProfileRules.dateParts("05/2019").month, 5)
        XCTAssertNil(ProfileRules.dateParts("Present").endYear)
    }

    func testImplausibleAnswersAreNotUsed() async throws {
        XCTAssertFalse(plausible(field("Postal Code"), "80000 USD"))
        XCTAssertTrue(plausible(field("Postal Code"), "78701"))
        XCTAssertTrue(plausible(field("Zip/Postal code"), "SW1A 1AA"))
        XCTAssertFalse(plausible(field("Phone"), "LinkedIn"))
        XCTAssertFalse(plausible(field("Graduation year"), "May"))
        XCTAssertTrue(plausible(field("End date month"), "June"))
        XCTAssertFalse(plausible(field("End date month"), "2019"))
        XCTAssertTrue(plausible(field("Did you hear about us on LinkedIn?"), "Yes"))
        // A wrong answer the AI saved before is dropped and forgotten.
        let home = try TestHome()
        let zip = FieldSpec(id: "z", label: "Postal Code", required: true)
        home.db.cachePut(Answerer.hash(zip), question: "Postal Code", fieldType: "text", options: [], answer: "80000 USD", source: "llm:high")
        let res = await Answerer(profile: profile, db: home.db, ai: nil).resolve([zip], job: Fixture.job)
        XCTAssertEqual(res.answers["z"], "78701")
        XCTAssertNil(home.db.cacheGet(Answerer.hash(zip)))
    }

    func testConsentBoxesAndSignUps() {
        XCTAssertEqual(ProfileRules.answer(profile, FieldSpec(id: "1", label: "I acknowledge the Candidate Privacy Notice *", type: .checkbox, required: true)), "Yes")
        XCTAssertEqual(ProfileRules.answer(profile, FieldSpec(id: "2", label: "Join our Talent Community *", type: .radio, options: ["Yes", "No"], required: true)), "No")
        XCTAssertEqual(ProfileRules.answer(profile, FieldSpec(id: "3", label: "I agree to receive text messages about my application", type: .checkbox)), "No")
        XCTAssertEqual(ProfileRules.answer(profile, FieldSpec(id: "4", label: "I consent to the above.", type: .checkbox, required: true)), "Yes")
        XCTAssertNil(ProfileRules.answer(profile, FieldSpec(id: "5", label: "Do you agree to a background check?", type: .radio, options: ["Yes", "No"])))
    }

    func testSameQuestionInOtherWordsIsAnsweredOnce() throws {
        XCTAssertEqual(QuestionTopic(question: "What gender are you?"), .gender)
        XCTAssertEqual(QuestionTopic(question: "Please select your gender."), .gender)
        XCTAssertEqual(QuestionTopic(question: "Pronouns *"), .pronouns)
        XCTAssertEqual(QuestionTopic(question: "Are you Hispanic or Latino?"), .hispanic)
        XCTAssertNil(QuestionTopic(question: "Education › Start date month"))
        let home = try TestHome()
        let asked: [(String, String, [String])] = [("What gender are you?", "radio", ["Male", "Female", "Non-binary"]),
                                                   ("Please select your gender.", "select", ["Select", "Male", "Female"]),
                                                   ("Pronouns *", "text", [])]
        for (i, q) in asked.enumerated() {
            home.db.addPending(questionHash(q.0, q.1, q.2), question: q.0, fieldType: q.1, options: q.2, jobID: "j\(i)", company: "Co \(i)")
        }
        XCTAssertEqual(QuestionGroups.group(home.db.listPending()).count, 2)
        var p = profile
        let gender = try XCTUnwrap(home.db.listPending().first { $0.question == "What gender are you?" })
        XCTAssertEqual(QuestionGroups.answer(gender, with: "Male", db: home.db, profile: &p), 2)
        XCTAssertEqual(p.eeo.gender, "Male")
        XCTAssertEqual(home.db.listPending().map(\.question), ["Pronouns *"])
        // The next form that asks it in other words is answered from the profile.
        XCTAssertEqual(ProfileRules.answer(p, FieldSpec(id: "g", label: "Gender", type: .select, options: ["Male", "Female"])), "Male")
        var q = profile
        XCTAssertTrue(QuestionTopic.salary.learn("$95k", into: &q))
        XCTAssertEqual(q.compensation.desiredBase, 95000)
        XCTAssertFalse(QuestionTopic.relocate.learn("Maybe", into: &q))
    }

    func testAnsweredJobsAreFinishedFirst() throws {
        let home = try TestHome()
        home.db.upsertJob("1", status: .needsAnswer, title: "A", company: "X", url: "https://www.linkedin.com/jobs/view/1/")
        home.db.upsertJob("2", status: .needsAnswer, title: "B", company: "Y", url: "https://www.linkedin.com/jobs/view/2/")
        home.db.addPending("h", question: "Q", fieldType: "text", options: [], jobID: "2", company: "Y")
        XCTAssertEqual(home.db.answeredJobs().map(\.id), ["1"])
        home.db.resolvePending("h", answer: "A")
        XCTAssertEqual(Set(home.db.answeredJobs().map(\.id)), ["1", "2"])
    }

    /// "4 weeks after offer" goes into a box that wants a date (Paylocity's "Available to Start", MM/DD/YYYY) as one;
    /// a question that takes words keeps the words.
    func testStartDateIsADateWhenTheBoxAsksForOne() {
        let today = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 11, day: 15).date!
        let box = FieldSpec(id: "a", label: "Available to Start", placeholder: "MM/DD/YYYY")
        XCTAssertEqual(ProfileRules.startDate("4 weeks after offer", for: box, today: today), "12/13/2026")
        XCTAssertEqual(ProfileRules.startDate("2 weeks", for: FieldSpec(id: "b", label: "Desired start date"), today: today), "11/29/2026")
        XCTAssertEqual(ProfileRules.startDate("Immediately", for: FieldSpec(id: "c", label: "Start", type: .date), today: today), "2026-11-15")
        XCTAssertEqual(ProfileRules.startDate("4 weeks after offer", for: FieldSpec(id: "d", label: "When can you start?"), today: today), "4 weeks after offer")
        XCTAssertEqual(ProfileRules.startDate("01/05/2027", for: box, today: today), "01/05/2027")
    }

    /// LinkedIn's "Location (city)" suggests "Austin, Texas, United States" as you type: the city with its state.
    func testLocationCityIsTheCityWithItsState() {
        XCTAssertEqual(ProfileRules.answer(Fixture.profile, FieldSpec(id: "l", label: "Location (city)", type: .combobox)), "Austin, TX")
        XCTAssertEqual(ProfileRules.answer(Fixture.profile, FieldSpec(id: "c", label: "City")), "Austin")
    }

    /// A job's whole "Start date" box (Dayforce, Avature): the profile's "2022" as the box writes dates. A current
    /// job's end date only where it's required anyway, as this month.
    func testWholeStartAndEndDatesOfAJob() {
        var p = Fixture.profile
        p.workHistory = [Role(company: "Globex Corporation (GC) – Pacific", title: "Software Engineer (Intern)", startDate: "2022", endDate: "Present"),
                         Role(company: "Initech", title: "Analyst", startDate: "June 2019", endDate: "Aug 2021")]
        let start = FieldSpec(id: "s", label: "Start Date", required: true, section: "Work experience")
        XCTAssertEqual(ProfileRules.answer(p, start), "01/01/2022")
        XCTAssertEqual(ProfileRules.answer(p, FieldSpec(id: "d", label: "Start Date", type: .date, section: "Work experience")), "2022-01-01")
        XCTAssertEqual(ProfileRules.answer(p, FieldSpec(id: "m", label: "From", placeholder: "MM/YYYY", section: "Work experience")), "01/2022")
        XCTAssertNil(ProfileRules.answer(p, FieldSpec(id: "e", label: "End Date", section: "Work experience")), "a current job's end date stays empty")
        let today = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 11, day: 15).date!
        XCTAssertEqual(ProfileRules.work(p, FieldSpec(id: "r", label: "End date", required: true, section: "Work experience"), "end date", today: today),
                       "11/01/2026")
        p.workHistory.removeFirst()
        XCTAssertEqual(ProfileRules.answer(p, FieldSpec(id: "e2", label: "End Date", section: "Work experience")), "08/01/2021")
        p.education = [Education(school: "Nevada State University", degree: "MEng", graduationDate: "2024-2026")]
        XCTAssertEqual(ProfileRules.answer(p, FieldSpec(id: "es", label: "Start Date", type: .date, section: "Education")), "2024-01-01")
        XCTAssertEqual(ProfileRules.answer(p, FieldSpec(id: "ee", label: "End Date", section: "Education")), "01/01/2026")
    }

    /// A list named only "Select" (its question wasn't found): never answered, not even by the AI.
    func testABoxNamedOnlySelectIsNotGuessed() async throws {
        let home = try TestHome()
        let model = FakeModel(["Select": ("Yes", .high)])
        let answerer = Answerer(profile: Fixture.profile, db: home.db, ai: AIService(model: model))
        let res = await answerer.resolve([FieldSpec(id: "q", label: "Select", type: .combobox, options: ["Yes", "No"], required: true)], job: Fixture.job)
        XCTAssertNil(res.answers["q"])
        XCTAssertEqual(res.unresolved.map(\.id), ["q"])
    }
}

