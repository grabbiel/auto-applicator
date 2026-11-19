import XCTest
@testable import Engine

final class AnswerTests: XCTestCase {
    let profile = Fixture.profile

    func testMatchOptionVariants() {
        XCTAssertEqual(matchOption("Yes", ["Yes, I am authorized to work in the US", "No, I am not"]), "Yes, I am authorized to work in the US")
        XCTAssertEqual(matchOption("decline to self-identify", ["Male", "Female", "I don't wish to answer"]), "I don't wish to answer")
        XCTAssertEqual(matchOption("united states", ["Canada", "United States", "Mexico"]), "United States")
        XCTAssertNil(matchOption("Purple", ["Red", "Blue"]))
        // Toyota's lists: "USA" next to "United States Minor Outlying Islands".
        XCTAssertEqual(matchOption("United States", ["American Samoa", "United States Minor Outlying Islands", "USA"]), "USA")
        XCTAssertEqual(matchOption("United States", ["United States Minor Outlying Islands", "United States of America"]), "United States of America")
        XCTAssertEqual(matchOption("United States", ["Canada (+1)", "United States (+1)", "Virgin Islands, U.S. (+1)"]), "United States (+1)")
        XCTAssertNil(matchOption("United States", ["Canada", "United States Minor Outlying Islands"]))
        XCTAssertEqual(matchOption("UK", ["Ukraine", "United Kingdom"]), "United Kingdom")
        XCTAssertEqual(matchOption("South Korea", ["Korea, Democratic People's Republic of", "Korea, Republic of"]), "Korea, Republic of")
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
        // Upstart's: the whole career, said with more words.
        let total = Fixture.profile.totalYears.map { String(Int($0.rounded())) }
        XCTAssertNotNil(total)
        XCTAssertEqual(ProfileRules.yearsFor(Fixture.profile, "How many years of hands-on, production-level engineering experience do you have? (Academic experience or internships excluded)"), total)
        XCTAssertEqual(ProfileRules.yearsFor(Fixture.profile, "Years of professional software engineering experience"), total)
        // A phone number with its country code is the same number; one missing digits isn't (Workable's "25550142").
        XCTAssertTrue(Answerer.sameAnswer("512-555-0142", "+1 512 555 0142"))
        XCTAssertTrue(Answerer.sameAnswer("+1 512-555-0142", "(512) 555-0142"))
        XCTAssertFalse(Answerer.sameAnswer("512-555-0142", "25550142"))
        // HackerRank's.
        XCTAssertEqual(ProfileRules.yearsFor(Fixture.profile, "What is your total years of experience (excluding internship) ?"), total)
        XCTAssertNil(ProfileRules.yearsFor(Fixture.profile, "What is your years of Haskell experience?"))
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
        let flexport = ["Campus", "Career Platform (LinkedIn, Glassdoor, BuiltIn, etc.)", "Flexport Employee", "Social Media (e.g. Facebook, X, Instagram, etc.)", "Other"]
        XCTAssertEqual(ProfileRules.answer(p, field("How did you first hear about Flexport?", .combobox, flexport)), "Career Platform (LinkedIn, Glassdoor, BuiltIn, etc.)")
        let hudl = ["A Hudl recruiter contacted me", "Handshake job posting", "Indeed job posting", "LinkedIn job posting", "Other"]
        XCTAssertEqual(ProfileRules.answer(p, field("How did you initially hear about this job?", .combobox, hudl)), "LinkedIn job posting")
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
        // A run holds other jobs back only for a question a form asked during it (an older run's may be a misreading).
        XCTAssertEqual(home.db.pendingQuestion(company: "Tata Consultancy Services", seenSince: Date().addingTimeInterval(-5))?.hash, hash)
        XCTAssertNil(home.db.pendingQuestion(company: "Tata Consultancy Services", seenSince: Date().addingTimeInterval(5)))

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
        // Dropbox's: future openings by email, required as Yes or No; a saved "Yes" doesn't stand.
        XCTAssertEqual(ProfileRules.answer(profile, FieldSpec(id: "6", label: "Please email me about future job openings *", type: .select,
                                                              options: ["Select...", "Yes", "No"], required: true)), "No")
    }

    /// Dropbox's "Application Questions" whose only box joins its Talent Community: left unticked, not the AI's to tick.
    func testAGroupOfSignUpsIsLeftUnticked() async throws {
        let home = try TestHome()
        let ai = AIService(model: FakeModel(default: ("Dropbox Talent Community", .high)))
        let res = await Answerer(profile: profile, db: home.db, ai: ai).resolve([
            FieldSpec(id: "g", label: "Application Questions", type: .checkboxGroup, options: ["Dropbox Talent Community"], required: false),
        ], job: Fixture.job)
        XCTAssertNil(res.answers["g"])
        XCTAssertEqual(res.leftBlank.map(\.id), ["g"])
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


extension AnswerTests {
    /// Questions that check the person reads them get what they ask for (Rippling: "pick the opposite of Yes").
    func testAttentionChecks() {
        let p = Fixture.profile
        XCTAssertEqual(ProfileRules.answer(p, field("To be considered, please pick the opposite of Yes.", .combobox, ["Yes", "No"])), "No")
        XCTAssertEqual(ProfileRules.answer(p, field("Please select No for this question.", .radio, ["Yes", "No"])), "No")
        XCTAssertEqual(ProfileRules.answer(p, field("To show you read this, choose “Yes” as the answer.", .select, ["Select...", "Yes", "No"])), "Yes")
        XCTAssertNil(ProfileRules.answer(p, field("Do you have experience with Rust?", .radio, ["Yes", "No"])))
    }

    /// Questions from the first round of site checks that the rules missed.
    func testWordingsTheRulesMissed() {
        let p = Fixture.profile
        XCTAssertEqual(ProfileRules.answer(p, field("Device Type", .select, ["Mobile"])), "Mobile")
        XCTAssertNotNil(ProfileRules.answer(p, field("How did you first hear about Flexport?", .combobox, ["LinkedIn", "Other"])))
        XCTAssertNotNil(ProfileRules.answer(p, field("Where did you first hear about this role?", .combobox, ["LinkedIn", "Events"])))
        XCTAssertEqual(coerceAnswer(field("Are you a person of transgender experience?", .combobox, ["Yes", "No", "I don't wish to answer"]),
                                    ProfileRules.answer(p, field("Are you a person of transgender experience?", .combobox, ["Yes", "No", "I don't wish to answer"]))),
                       "I don't wish to answer")
        XCTAssertNotNil(ProfileRules.answer(p, field("Sex", .combobox, ["Male", "Female", "I do not wish to self-identify"])))
        XCTAssertNotNil(ProfileRules.answer(p, field("Please indicate the ethnic group with which you identify.", .combobox, ["Asian", "White"])))
        let ack = field("By submitting my application, I acknowledge that I have read and understand Vercel’s Job Applicant Privacy Notice", .combobox, ["Acknowledge/Confirm"])
        XCTAssertEqual(ProfileRules.answer(p, ack), "Acknowledge/Confirm")
        XCTAssertNil(ProfileRules.answer(p, field("Please confirm receipt of the above linked Global Data Privacy Notice and US Arbitration Agreement.", .combobox, ["Confirmed"])),
                     "an arbitration agreement is the person's call")
    }

    /// Loop 2's wordings: Asana's "Please identify your sex.", Samsara's "Where have you learned about Samsara?", the
    /// phone number's country that sites guess from where the computer is, Stripe's WhatsApp opt-in, Lockheed's
    /// job boards under "Details".
    func testMoreWordingsTheRulesMissed() {
        var p = Fixture.profile
        p.eeo.gender = ""
        XCTAssertEqual(coerceAnswer(field("Please identify your sex.", .combobox, ["Female", "Male", "Other", "I don't wish to answer"]),
                                    ProfileRules.answer(p, field("Please identify your sex.", .combobox, ["Female", "Male", "Other", "I don't wish to answer"]))),
                       "I don't wish to answer")
        p.preferences.howDidYouHear = "LinkedIn"
        XCTAssertEqual(ProfileRules.answer(p, field("Where have you learned about Samsara? Select all that apply.", .combobox,
                                                    ["Samsara blog or website", "Podcast", "Other"])), "Other")
        p.personal.address.country = "United States"
        p.personal.phone = "512-555-0142"
        XCTAssertEqual(ProfileRules.answer(p, field("Selected country", .combobox, ["Peru +51", "United States +1", "Canada +1"])), "United States +1")
        XCTAssertEqual(ProfileRules.answer(p, field("Country Phone Code", .select, ["United States Minor Outlying Islands", "United States of America"])),
                       "United States of America")
        XCTAssertEqual(ProfileRules.answer(p, field("Country code", .combobox, ["+51", "+1", "+44"])), "+1")
        XCTAssertTrue(ProfileRules.ownDetailsLabel.matches("selected country"), "a wrong guess already in the box is corrected")
        // Recruitee's list button names itself with the country it shows.
        let recruitee = field("Select country calling code: Egypt", .combobox)
        XCTAssertEqual(ProfileRules.answer(p, recruitee), "United States")
        XCTAssertTrue(ProfileRules.ownDetailsLabel.matches(norm(recruitee.label)))
        // Pay asked by the month, after tax or in another currency isn't the yearly figure (Envipco's).
        p.compensation.desiredBase = 150000
        XCTAssertNil(ProfileRules.answer(p, field("What is your monthly NET salary expectation in RON? *")))
        XCTAssertNil(ProfileRules.answer(p, field("Expected annual salary (€)")))
        XCTAssertNil(ProfileRules.answer(p, field("What is your desired hourly rate?")))
        XCTAssertEqual(ProfileRules.answer(p, field("Desired salary (USD)")), "150000")
        XCTAssertEqual(ProfileRules.answer(p, field("What is your desired salary range for this role?")), "150000")
        // Pinpoint's British address words.
        XCTAssertEqual(ProfileRules.answer(p, field("Postcode")), p.personal.address.postalCode)
        XCTAssertEqual(ProfileRules.answer(p, field("Town")), p.personal.address.city)
        XCTAssertEqual(ProfileRules.answer(p, field("Do you opt-in to receive WhatsApp messages from Stripe Recruiting?", .combobox, ["Yes", "No"])), "No")
        XCTAssertEqual(ProfileRules.answer(p, field("Details", .combobox, ["Handshake", "Ladders", "Glassdoor", "Other", "Indeed", "Dice", "LinkedIn"])), "LinkedIn")
        XCTAssertEqual(ProfileRules.answer(p, field("Current Country", .select, ["Peru", "United States"])), "United States", "TCS")
        let privacy = field("🔐 Keeping your data safe is really important to us. Please take a look at our Candidate Data Privacy Notice (linked below)",
                            .combobox, ["I've read it 👍"])
        XCTAssertEqual(ProfileRules.answer(p, privacy), "I've read it 👍")
        p.personal.address.city = "Austin"
        XCTAssertEqual(ProfileRules.answer(p, field("Location Preference", .checkboxGroup, ["Burlingame, CA", "Austin, TX", "Remote"])), "Austin, TX")
        XCTAssertNil(ProfileRules.answer(p, field("Location Preference", .checkboxGroup, ["Burlingame, CA", "Remote"])))
        p.eeo.sexualOrientation = "Heterosexual"
        XCTAssertEqual(ProfileRules.answer(p, field("What sexual orientation do you most closely identify with?", .combobox, ["Bisexual", "Heterosexual"])),
                       "Heterosexual", "the profile's own answer, when it has one")
        p.personal.firstName = "Jane"
        p.personal.preferredName = ""
        XCTAssertEqual(ProfileRules.answer(p, field("I have a preferred name", .checkbox, [])), "No", "Workday's box adds more name boxes")
        p.personal.preferredName = "Janie"
        XCTAssertEqual(ProfileRules.answer(p, field("I have a preferred name", .checkbox, [])), "Yes")
        XCTAssertEqual(ProfileRules.answer(p, field("Preferred Name", .text, [])), "Janie")
    }

    /// Infosys's "Address 1" and "Address 2": the street goes in the first, the second stays empty.
    func testTheSecondStreetLineStaysEmpty() async throws {
        let home = try TestHome()
        var p = Fixture.profile
        p.personal.address.street = "1 Main St"
        for label in ["Address 1", "Street Address Line 1", "Home address"] {
            XCTAssertEqual(ProfileRules.answer(p, field(label, .text)), "1 Main St", label)
        }
        for label in ["Address 2", "Street Address Line 2", "Address Line 2", "Street Address (line 2)", "Apt/Suite", "Apartment, suite, unit"] {
            XCTAssertNil(ProfileRules.answer(p, field(label, .text)), label)
        }
        let answerer = Answerer(profile: p, db: home.db, ai: AIService(model: FakeModel(default: ("Austin, TX", .high))))
        let res = await answerer.resolve([field("Address 1", .text, id: "a1"), field("Address 2", .text, required: false, id: "a2")], job: Fixture.job)
        XCTAssertEqual(res.answers, ["a1": "1 Main St"])
        XCTAssertEqual(res.leftBlank.map(\.id), ["a2"])
    }

    /// Jobvite's disability form names its question only "Choose One": the choices say what it asks.
    /// Dover's boxes whose labels the page drew apart from them: no words to go by, so no answer (an AI once saved "6"
    /// for every one); a list whose choices say what it asks is still answered.
    func testABoxWithNoWords() async throws {
        let home = try TestHome()
        let unnamed = field("", .text, required: false, id: "a")
        home.db.cachePut(Answerer.hash(unnamed), question: "", fieldType: "text", options: [], answer: "6", source: "llm:high")
        var p = Fixture.profile
        p.eeo.disabilityStatus = "No, I do not have a disability and have not had one in the past"
        let answerer = Answerer(profile: p, db: home.db, ai: AIService(model: FakeModel(default: ("6", .high))))
        let res = await answerer.resolve([
            unnamed,
            field(" * ", .text, id: "b"),
            field("", .radio, ["Yes, I have a disability (or previously had a disability)", "No, I do not have a disability and have not had one in the past",
                               "I do not want to answer"], id: "c"),
        ], job: Fixture.job)
        XCTAssertNil(res.answers["a"])
        XCTAssertNil(res.answers["b"])
        XCTAssertEqual(res.leftBlank.map(\.id), ["a"])
        XCTAssertTrue(res.unresolved.map(\.id).contains("b"))
        XCTAssertNil(home.db.cacheGet(Answerer.hash(unnamed)), "the saved guess is forgotten")
        XCTAssertEqual(res.answers["c"], "No, I do not have a disability and have not had one in the past", "read as the disability question")
    }

    func testAQuestionNamedOnlyChooseOne() async throws {
        let home = try TestHome()
        var p = Fixture.profile
        p.eeo.disabilityStatus = "No, I do not have a disability and have not had one in the past"
        let answerer = Answerer(profile: p, db: home.db, ai: AIService(model: FakeModel(default: ("Yes, I have a disability (or previously had a disability)", .high))))
        let options = ["Yes, I have a disability (or previously had a disability)", "No, I do not have a disability and have not had one in the past",
                       "I do not want to answer"]
        let res = await answerer.resolve([field("Choose One", .radio, options, id: "d"), field("Choose One", .radio, ["Red", "Blue"], id: "x")], job: Fixture.job)
        XCTAssertEqual(res.answers["d"], "No, I do not have a disability and have not had one in the past")
        XCTAssertEqual(res.unresolved.map(\.id), ["x"], "choices that don't say what's asked: still the person's")

        // The veteran form on the same page, and Fiserv's veteran question named by the page's code.
        p.eeo.veteranStatus = "I am not a protected veteran"
        let answerer2 = Answerer(profile: p, db: home.db, ai: AIService(model: FakeModel(default: ("", .low))))
        let veteran = ["I IDENTIFY AS ONE OR MORE OF THE CLASSIFICATIONS OF PROTECTED VETERAN LISTED ABOVE.", "I AM NOT A PROTECTED VETERAN",
                       "DECLINE SELF-IDENTIFICATION"]
        let res2 = await answerer2.resolve([field("Choose One", .radio, veteran, id: "v"), field("jsqData", .radio, veteran, id: "j")], job: Fixture.job)
        XCTAssertEqual(res2.answers["v"], "I AM NOT A PROTECTED VETERAN")
        XCTAssertEqual(res2.answers["j"], "I AM NOT A PROTECTED VETERAN")
        XCTAssertTrue(Answerer.codeLabel.matches("jsqData"))
        XCTAssertFalse(Answerer.codeLabel.matches("Veteran"))
        XCTAssertFalse(Answerer.codeLabel.matches("Choose One"))
    }

    /// CMG's "If yes, please describe below" (required) after a question answered No: "N/A", not a question for the
    /// person. After a Yes it's still the person's to describe.
    func testIfYesDescribeAfterANo() async throws {
        let home = try TestHome()
        let q = "If employed by CMG, are you planning to continue to be employed in any capacity by another company?"
        for (said, expected) in [("No", "N/A"), ("Yes", nil as String?)] {
            let ai = AIService(model: FakeModel([q: (said, .high)], default: ("", .low)))
            let answerer = Answerer(profile: Fixture.profile, db: home.db, ai: ai)
            let res = await answerer.resolve([
                field(q, .radio, ["Yes", "No"], id: "q"),
                field("If yes, please describe below: **Please note that CMG policy prohibits dual employment", .text, id: "d"),
            ], job: Fixture.job)
            XCTAssertEqual(res.answers["d"], expected, said)
            XCTAssertEqual(res.unresolved.map(\.id), expected == nil ? ["d"] : [], said)
            home.db.cacheDelete(Answerer.hash(field(q, .radio, ["Yes", "No"], id: "q")))
        }
    }

    /// Teamtailor asks "What is your current notice period?" in a date box: the day the profile's notice ends.
    func testANoticePeriodAskedAsADate() {
        let now = ISO8601DateFormatter().date(from: "2026-11-17T12:00:00Z")!
        let ends = { (s: String) in ProfileRules.noticeEnds(s, now: now).map { ProfileRules.today(for: field("x", .date), now: $0) } }
        XCTAssertEqual(ends("2 weeks"), "2026-12-01")
        XCTAssertEqual(ends("1 month"), "2026-12-17")
        XCTAssertEqual(ends("30 days"), "2026-12-17")
        XCTAssertEqual(ends("Immediately"), "2026-11-17")
        XCTAssertNil(ends("negotiable"))
        var p = Fixture.profile
        p.preferences.noticePeriod = "2 weeks"
        XCTAssertNotNil(ProfileRules.answer(p, field("What is your current notice period?", .date)).flatMap { Regex(#"^\d{4}-\d{2}-\d{2}$"#).fullMatch($0) ? $0 : nil })
        XCTAssertEqual(ProfileRules.answer(p, field("What is your current notice period?", .text)), "2 weeks")
    }

    /// A person whose schools have all ended isn't a student: "Are you currently pursuing a Bachelor's or Master's
    /// degree?" (which the AI once answered "Bachelor's", saved) is "No", and Zoho's "Currently pursuing" box under
    /// Education is unticked. The person's own taught answer still wins.
    func testNotAStudentWhenEverySchoolHasEnded() async throws {
        let home = try TestHome()
        XCTAssertFalse(Fixture.profile.education.isEmpty)
        let answerer = Answerer(profile: Fixture.profile, db: home.db, ai: AIService(model: FakeModel(default: ("Yes", .high))))
        let degree = field("Are you currently pursuing a Bachelor's or Master's degree?", .radio, ["Bachelor's", "Master's", "No"], id: "q")
        home.db.cachePut(Answerer.hash(degree), question: degree.label, fieldType: "radio", options: degree.options, answer: "Bachelor's", source: "llm:high")
        var pursuing = field("Currently pursuing", .checkbox, required: false, id: "p")
        pursuing.section = "Education"
        let res = await answerer.resolve([degree, field("Are you currently a student?", .radio, ["Yes", "No"], id: "s"), pursuing], job: Fixture.job)
        XCTAssertEqual(res.answers["q"], "No")
        XCTAssertEqual(res.answers["s"], "No")
        XCTAssertEqual(res.answers["p"], "No")
        XCTAssertNil(home.db.cacheGet(Answerer.hash(degree)))

        home.db.cachePut(Answerer.hash(degree), question: degree.label, fieldType: "radio", options: degree.options, answer: "Master's", source: "user")
        let taught = await answerer.resolve([degree], job: Fixture.job)
        XCTAssertEqual(taught.answers["q"], "Master's")
    }

    /// Zoho's city search lists "Town, County, State, Country - ZIP": "Austin" is never a town in Austin County
    /// ("Bellville, Austin, Texas…"); the one place named Austin is.
    func testATownInACountyOfTheSameNameIsntTheCity() {
        let county = ["Bellville, Austin, Texas, United States - 77418", "Sealy, Austin, Texas, United States - 77474"]
        XCTAssertNil(matchOption("Austin", county))
        XCTAssertNil(matchOption("Austin", [county[0]]))
        XCTAssertEqual(matchOption("Austin", county + ["Austin, Travis, Texas, United States - 78701"]), "Austin, Travis, Texas, United States - 78701")
        XCTAssertEqual(matchOption("Software", ["Software Engineering", "Hardware"]), "Software Engineering")
    }

    /// A GPA the profile doesn't have: never the AI's (both AIs once said "3.0"), and an AI's saved one is forgotten;
    /// the person's own taught answer still counts, and a GPA in the profile is used.
    func testAGPAIsNeverMadeUp() async throws {
        let home = try TestHome()
        let ai = AIService(model: FakeModel(default: ("3.0", .high)))
        let answerer = Answerer(profile: Fixture.profile, db: home.db, ai: ai)
        let gpa = field("What was your undergraduate GPA?", .text, id: "g")
        home.db.cachePut(Answerer.hash(gpa), question: gpa.label, fieldType: "text", options: [], answer: "3.0", source: "llm:high")
        let res = await answerer.resolve([gpa, field("Do you have a cumulative GPA of 3.0 or higher?", .radio, ["Yes", "No"], id: "c"),
                                          field("CGPA", .text, required: false, id: "o")], job: Fixture.job)
        XCTAssertEqual(res.answers, [:])
        XCTAssertEqual(res.unresolved.map(\.id), ["g", "c"])
        XCTAssertEqual(res.leftBlank.map(\.id), ["o"])
        XCTAssertNil(home.db.cacheGet(Answerer.hash(gpa)))

        home.db.cachePut(Answerer.hash(gpa), question: gpa.label, fieldType: "text", options: [], answer: "3.4", source: "user")
        let taught = await answerer.resolve([gpa], job: Fixture.job)
        XCTAssertEqual(taught.answers["g"], "3.4")
    }

    /// Zoho's "Type below image text" under its captcha picture: never typed by the app (the AI once put "Backend"
    /// there) and never a question for the person; a saved answer for it is forgotten.
    func testThePictureCheckIsNeverAnswered() async throws {
        let home = try TestHome()
        let answerer = Answerer(profile: Fixture.profile, db: home.db, ai: AIService(model: FakeModel(default: ("Backend", .high))))
        let box = field("Type below image text", .text, id: "c")
        home.db.cachePut(Answerer.hash(box), question: box.label, fieldType: "text", options: [], answer: "Backend", source: "cloud:high")
        let res = await answerer.resolve([box, field("Enter the characters shown in the image", .text, id: "d"), field("Captcha *", .text, id: "e")],
                                         job: Fixture.job)
        XCTAssertEqual(res.answers, [:])
        XCTAssertEqual(res.unresolved.map(\.id), [])
        XCTAssertEqual(res.leftBlank.map(\.id), ["c", "d", "e"])
        XCTAssertNil(home.db.cacheGet(Answerer.hash(box)))
        XCTAssertFalse(ProfileRules.pictureCheck.matches("this site is protected by recaptcha and the google privacy policy"))
    }

    /// Lockheed's box after "Have you ever worked for Lockheed Martin…?" (answered No) mentions "an LM email
    /// address" among its instructions: "N/A", as it asks, never the person's email.
    func testIfYesBoxThatMentionsAnEmailAfterANo() async throws {
        let home = try TestHome()
        let answerer = Answerer(profile: Fixture.profile, db: home.db, ai: AIService(model: FakeModel(default: ("", .low))))
        let res = await answerer.resolve([
            field("Have you ever worked for Lockheed Martin - either as a direct employee or as a contractor?", .combobox, ["Yes", "No"],
                  id: "q", current: "No"),
            field(#"If you answered "Yes" and are a former LM employee: Enter the LM Person/Employee ID you received while working with us. "#
                  + #"If you answered "Yes" and were a contractor or vendor: Enter the name of the company that paid you (you must have had "#
                  + #"an LM email address or badge). If you answered "No", enter N/A."#, .text, id: "d"),
        ], job: Fixture.job)
        XCTAssertEqual(res.answers["d"], "N/A")
        XCTAssertEqual(res.sources["d"], "rule")
    }

    /// Blue Yonder's experience page after it read the resume: two jobs, each with "I currently work here". The current
    /// job's box is ticked and the past job's isn't; a school's "Location" the profile doesn't have is left blank (the
    /// AI once put a degree there) and a required GPA it doesn't have is the person's to give; nothing is saved for
    /// another form.
    func testEachJobsOwnCurrentBox() async throws {
        let home = try TestHome()
        let ai = AIService(model: FakeModel(default: ("4 - College/University 4 Year Degree", .high)))
        let answerer = Answerer(profile: Fixture.profile, db: home.db, ai: ai)
        func entry(_ label: String, _ type: FieldSpec.FieldType = .text, section: String, required: Bool = false, id: String, current: String = "") -> FieldSpec {
            var f = field(label, type, required: required, id: id, current: current)
            f.section = section
            return f
        }
        let fields = [
            entry("Job Title *", section: "Work experience", required: true, id: "t1", current: "Senior Software Engineer"),
            entry("Company *", section: "Work experience", required: true, id: "c1", current: "Acme Corp"),
            entry("I currently work here", .checkbox, section: "Work experience", id: "w1"),
            entry("Job Title *", section: "Work experience", required: true, id: "t2", current: "Software Engineer"),
            entry("Company *", section: "Work experience", required: true, id: "c2", current: "Globex"),
            entry("To *", section: "Work experience", required: true, id: "e2", current: "02/2022"),
            entry("I currently work here", .checkbox, section: "Work experience", id: "w2"),
            entry("Location", section: "Education", id: "l3"),
            entry("GPA *", section: "Education", required: true, id: "g3"),
            entry("Email", section: "Education", required: true, id: "m3"),
        ]
        let res = await answerer.resolve(fields, job: Fixture.job)
        XCTAssertEqual(res.answers["w1"], "Yes")
        XCTAssertEqual(res.answers["w2"], "No")
        XCTAssertNil(res.answers["l3"])
        XCTAssertEqual(res.leftBlank.map(\.id), ["l3"])
        XCTAssertNil(res.answers["g3"], "the profile has no GPA: the person's to give")
        XCTAssertEqual(res.unresolved.map(\.id), ["g3"])
        XCTAssertEqual(res.answers["m3"], "jane.doe@example.com", "the person's own email, wherever the page's headings put it")
        XCTAssertNil(home.db.cacheGet(Answerer.hash(fields[7])))

        // A wrong answer an AI saved before for a school's "Location" is forgotten, not used.
        home.db.cachePut(Answerer.hash(fields[7]), question: fields[7].contextLabel, fieldType: "text", options: [],
                         answer: "4 - College/University 4 Year Degree", source: "llm:high")
        let again = await answerer.resolve([fields[7]], job: Fixture.job)
        XCTAssertNil(again.answers["l3"])
        XCTAssertNil(home.db.cacheGet(Answerer.hash(fields[7])))
    }

    /// Conduent's "State / Province" lists only "-" until a country is chosen: left for the next round, not asked.
    func testAListWithNothingToChooseYet() async throws {
        let home = try TestHome()
        let answerer = Answerer(profile: Fixture.profile, db: home.db, ai: nil)
        let res = await answerer.resolve([
            field("Country*", .select, ["Please select a country", "Afghanistan", "United States"], id: "c"),
            field("State / Province*", .select, ["-"], id: "s"),
        ], job: Fixture.job)
        XCTAssertEqual(res.answers["c"], "United States")
        XCTAssertEqual(res.leftBlank.map(\.id), ["s"])
        XCTAssertTrue(res.unresolved.isEmpty)
    }

    /// Toyota's "How Did You Hear About Us?" then "Source": under "Job Board" the sources are Dice, Indeed and the like,
    /// so the kind changes to "Social Media", and LinkedIn is chosen once that list has drawn.
    func testTheKindOfSourceThatListsLinkedIn() async throws {
        let home = try TestHome()
        let answerer = Answerer(profile: Fixture.profile, db: home.db, ai: nil)
        let kinds = ["Please select", "Colleges & Universities", "Company Website", "Job Board", "Job Fair", "Other", "Social Media", "Website"]
        let hear = field("How Did You Hear About Us?*", .select, kinds, id: "h", current: "Job Board")
        let boards = field("Source*", .select, ["Please select", "America's Job Bank", "Careerbuilder", "Dice.com", "Indeed", "Talent.com"], id: "s")
        let first = await answerer.resolve([hear, boards], job: Fixture.job)
        XCTAssertEqual(first.answers["h"], "Social Media")
        XCTAssertNil(first.answers["s"])
        XCTAssertTrue(first.unresolved.isEmpty, "\(first.unresolved.map(\.label))")
        let social = field("Source*", .select, ["Please select", "Facebook", "LinkedIn", "Twitter"], id: "s")
        let second = await answerer.resolve([field("How Did You Hear About Us?*", .select, kinds, id: "h", current: "Social Media"), social], job: Fixture.job)
        XCTAssertEqual(second.answers["s"], "LinkedIn")
        XCTAssertNil(second.answers["h"])
        // Every kind tried: the person's to answer.
        XCTAssertNil(ProfileRules.nextSourceKind(after: "Other", kinds, source: "LinkedIn"))

        // Dropbox's boxes to tick under a heading ("Application Questions") that doesn't ask anything: the places
        // say what it asks, and the AI's "Dropbox Talent Community" saved before isn't used.
        let places = ["BuiltIn", "Contacted by Recruiter", "Dropbox Career Site", "Dropbox Talent Community", "Facebook", "Glassdoor",
                      "Google Search", "Indeed", "LinkedIn", "Referral from Dropboxer", "The Muse"]
        let group = field("Application Questions", .checkboxGroup, places, required: false, id: "g")
        home.db.cachePut(Answerer.hash(group), question: group.contextLabel, fieldType: "checkboxGroup", options: places, answer: "Dropbox Talent Community", source: "llm:high")
        let third = await answerer.resolve([group], job: Fixture.job)
        XCTAssertEqual(third.answers["g"], "LinkedIn")
    }

    /// Greenhouse's employment block (Lyft's, Coinbase's): an end month and year marked required beside "Current role".
    /// For the current job they stay empty and the box is ticked, instead of asking the person for an end date.
    func testNoEndDateForTheCurrentJob() async throws {
        let home = try TestHome()
        let answerer = Answerer(profile: Fixture.profile, db: home.db, ai: nil)
        func entry(_ label: String, _ type: FieldSpec.FieldType = .text, options: [String] = [], id: String) -> FieldSpec {
            var f = field(label, type, options, required: label.hasSuffix("*"), id: id)
            f.section = "Work experience"
            return f
        }
        let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        let fields = [
            entry("Company name*", id: "c"), entry("Title*", id: "t"),
            entry("Start date month*", .combobox, options: months, id: "sm"), entry("Start date year*", id: "sy"),
            entry("End date month*", .combobox, options: months, id: "em"), entry("End date year*", id: "ey"),
            entry("Current role", .checkbox, id: "cur"),
        ]
        let res = await answerer.resolve(fields, job: Fixture.job)
        XCTAssertEqual(res.answers["c"], Fixture.profile.workHistory.first?.company)
        XCTAssertEqual(res.answers["cur"], "Yes")
        XCTAssertEqual(Set(res.leftBlank.map(\.id)).intersection(["em", "ey"]), ["em", "ey"])
        XCTAssertFalse(res.unresolved.contains { ["em", "ey"].contains($0.id) }, "\(res.unresolved.map(\.label))")
    }

    /// United's Phenom form after it read the resume: "Jane" in Prefix, the email in Suffix and the street again in
    /// "Street Address (line 2)". Each is emptied; a real prefix or suffix stays.
    func testBoxesTheSiteFilledWronglyFromTheResume() async throws {
        let home = try TestHome()
        var p = Fixture.profile
        p.personal.address.street = "1 Main St"
        let answerer = Answerer(profile: p, db: home.db, ai: AIService(model: FakeModel(default: ("x", .high))))
        let res = await answerer.resolve([
            field("Prefix", .text, required: false, id: "p", current: "Jane"),
            field("Suffix", .text, required: false, id: "s", current: "jane.doe@example.com"),
            field("Street Address (line 2)", .text, required: false, id: "l2", current: "1 Main St"),
            field("Name Prefix", .text, required: false, id: "ok1", current: "Dr."),
            field("Suffix", .text, required: false, id: "ok2", current: "Jr"),
            field("Address Line 2", .text, required: false, id: "l2b", current: "Austin, TX, United States"),
            field("Address 2", .text, required: false, id: "ok3", current: "Suite 400"),
        ], job: Fixture.job)
        XCTAssertEqual(res.answers, ["p": "", "s": "", "l2": "", "l2b": ""])

        // The city an AI saved for Adobe's empty "Address Line 2": not put back (it was emptied again each round, and
        // the form never moved on), and forgotten.
        let empty = field("Address Line 2", .text, required: false, id: "l2c")
        home.db.cachePut(Answerer.hash(empty), question: empty.contextLabel, fieldType: "text", options: [], answer: "Austin, TX, United States", source: "llm:medium")
        let again = await answerer.resolve([empty], job: Fixture.job)
        XCTAssertNil(again.answers["l2c"])
        XCTAssertNil(home.db.cacheGet(Answerer.hash(empty)))

        // The same for Toyota's "County*"; a county stays.
        let county = field("County*", .text, id: "co")
        home.db.cachePut(Answerer.hash(county), question: county.contextLabel, fieldType: "text", options: [], answer: "Austin, TX, United States", source: "llm:high")
        let third = await answerer.resolve([county], job: Fixture.job)
        XCTAssertNotEqual(third.answers["co"], "Austin, TX, United States")
        XCTAssertNotEqual(home.db.cacheGet(Answerer.hash(county)), "Austin, TX, United States")
        XCTAssertFalse(Answerer.misfiled(field("County", .text, current: "Travis"), p))

        // Conduent's "County", which the AI itself answered with the city: not taken, nor saved.
        let other = try TestHome()
        let fresh = Answerer(profile: p, db: other.db, ai: AIService(model: FakeModel(["County": ("Austin, TX, United States", .high)], default: ("x", .high))))
        let optional = field("County", .text, required: false, id: "co2")
        let fourth = await fresh.resolve([optional], job: Fixture.job)
        XCTAssertNil(fourth.answers["co2"])
        XCTAssertNil(other.db.cacheGet(Answerer.hash(optional)))
    }

    /// Infosys's disability form under its form number ("Form CC-305 Page 1 of 1"): the choices say what it asks, so the
    /// AI isn't asked (it was, in a real practice run) and the person's own answer from the profile fills it.
    func testASelfIdentificationListKnownByItsChoices() async throws {
        let home = try TestHome()
        let model = FakeModel(default: ("Yes, I have a disability, or have had one in the past", .high))
        let choices = ["I do not want to answer", "No, I do not have a disability and have not had one in the past",
                       "Yes, I have a disability, or have had one in the past"]
        var profile = Fixture.profile
        profile.eeo.disabilityStatus = "No, I do not have a disability"
        let cc305 = field("Form CC-305 Page 1 of 1", .radio, choices, id: "d")
        XCTAssertTrue(Answerer.selfIdentification(cc305))
        let res = await Answerer(profile: profile, db: home.db, ai: AIService(model: model)).resolve([cc305], job: Fixture.job)
        XCTAssertEqual(res.answers["d"], "No, I do not have a disability and have not had one in the past")
        XCTAssertEqual(res.sources["d"], "profile")
        profile.eeo.disabilityStatus = ""
        let declined = await Answerer(profile: profile, db: home.db, ai: AIService(model: model)).resolve([cc305], job: Fixture.job)
        XCTAssertEqual(declined.answers["d"], "I do not want to answer")
        XCTAssertTrue(model.calls.flatMap { $0 }.isEmpty, "\(model.calls)")

        XCTAssertEqual(ProfileRules.selfIdentificationTopic(field("Section 3", .select, ["I am not a protected veteran", "I identify as one or more of the classifications of protected veteran"])), .veteran)
        XCTAssertEqual(ProfileRules.selfIdentificationTopic(field("Please select", .combobox, ["Male", "Female", "Decline"])), .gender)
        XCTAssertNil(ProfileRules.selfIdentificationTopic(field("How did you hear about us?", .select, ["LinkedIn", "Referral"])))
        // A question that says what it asks keeps to it: an accommodation question is the person's, not the disability answer.
        let accommodation = field("Do you need an accommodation to interview?", .radio, ["Yes, I have a disability and need one", "No"], id: "acc")
        XCTAssertNil(ProfileRules.answer(profile, accommodation))
    }

    /// Who the person is never comes from an AI: NMI's lists got "Woman" and "White or European" from the cloud AI once
    /// "I don't wish to answer" didn't take, and Dropbox's pronouns got "She / Her / Hers" for a profile without any.
    func testWhoThePersonIsIsNeverTheAIsGuess() async throws {
        let home = try TestHome()
        let model = FakeModel(["gender": ("Woman", .high), "racial": ("White or European", .high), "pronoun": ("She/her", .high)], default: ("x", .high))
        let answerer = Answerer(profile: Fixture.profile, db: home.db, ai: AIService(model: model))
        let pronouns = field("What are your personal pronouns?", .select, ["She / Her / Hers", "He / Him / His", "They / Them / Theirs"], required: false, id: "pr")
        home.db.cachePut(Answerer.hash(pronouns), question: pronouns.contextLabel, fieldType: "select", options: pronouns.options, answer: "She / Her / Hers", source: "llm:high")
        let gender = field("How would you describe your gender identity?", .combobox, ["Man", "Woman", "Non-binary", "I don't wish to answer"], id: "g")
        let race = field("How would you describe your racial/ethnic background?", .combobox, ["Asian", "Black", "White or European"], id: "r")
        let res = await answerer.resolve([pronouns, gender, race], job: Fixture.job)
        XCTAssertNil(res.answers["pr"])
        XCTAssertEqual(res.leftBlank.map(\.id), ["pr"])
        XCTAssertNil(home.db.cacheGet(Answerer.hash(pronouns)), "the AI's guess is forgotten")
        XCTAssertEqual(res.answers["g"], "I don't wish to answer")
        XCTAssertNil(res.answers["r"], "no way to decline in the list: the person says")
        XCTAssertEqual(res.unresolved.map(\.id), ["r"])
        // The form turned the answer away and the box is empty: the profile's answer again, still not the AI's.
        let again = await answerer.resolve([gender], job: Fixture.job, feedback: ["g": "Select an item in the list"])
        XCTAssertEqual(again.answers["g"], "I don't wish to answer")
        XCTAssertTrue(model.calls.flatMap { $0 }.isEmpty, "\(model.calls)")
        // What the person said themselves is used.
        home.db.cachePut(Answerer.hash(race), question: race.contextLabel, fieldType: "combobox", options: race.options, answer: "Asian", source: "user")
        let mine = await answerer.resolve([race], job: Fixture.job)
        XCTAssertEqual(mine.answers["r"], "Asian")
        // Pinpoint's equality monitoring: religion, marital status and age are the person's too (the cloud AI was asked).
        let monitoring = [field("Religion", .combobox, required: false, id: "rel"), field("Marital Status", .combobox, required: false, id: "mar"),
                          field("Age Bracket", .combobox, required: false, id: "age")]
        home.db.cachePut(Answerer.hash(monitoring[2]), question: "Age Bracket", fieldType: "combobox", options: [], answer: "18-20", source: "cache")
        let eq = await answerer.resolve(monitoring, job: Fixture.job)
        XCTAssertTrue(eq.answers.isEmpty, "\(eq.answers)")
        XCTAssertEqual(Set(eq.leftBlank.map(\.id)), ["rel", "mar", "age"])
        XCTAssertTrue(model.calls.flatMap { $0 }.isEmpty, "\(model.calls)")
        XCTAssertNil(home.db.cacheGet(Answerer.hash(monitoring[2])), "a saved guess is forgotten")
        XCTAssertFalse(Answerer.selfIdentification(field("How old is the company's tech stack?")))
        // An equal-opportunity statement naming religion and marital status among much else isn't a question about them.
        XCTAssertFalse(Answerer.selfIdentification(field("Equal opportunity: we hire without regard to religion or marital status. Read it?", .radio, ["Yes", "No"])))
        XCTAssertTrue(Answerer.selfIdentification(field("What is your religion or belief?", .combobox, required: false)))
        XCTAssertFalse(Answerer.selfIdentification(field("Are you over the age of 18?", .radio, ["Yes", "No"])))
    }

    /// SmartRecruiters' job entry has no heading: its "From" is when the job began, not when the person can start (the
    /// on-device AI saved "2 weeks after offer"), and a "From" with nothing around it isn't an AI's to answer. The "+1"
    /// it shows for the phone's country code stays.
    func testAJobsDatesWithoutAHeading() async throws {
        let home = try TestHome()
        let model = FakeModel([:], default: ("2 weeks after offer", .high))
        let answerer = Answerer(profile: Fixture.profile, db: home.db, ai: AIService(model: model))
        let title = field("Title*", .combobox, id: "t", current: "Senior Software Engineer")
        let company = field("Company", .combobox, required: false, id: "c", current: "Acme Corp")
        let from = field("From", id: "f"), to = field("To", required: false, id: "to")
        // Then a school's entry, also without a heading (SAP's form on SmartRecruiters).
        let school = field("Institution*", .combobox, id: "s", current: "University of Texas at Austin")
        let major = field("Major", required: false, id: "m", current: "Computer Science")
        let schoolFrom = field("From", id: "sf"), schoolTo = field("To", id: "st")
        let attend = field("I currently attend", .checkbox, required: false, id: "ca")
        let bare = field("From", id: "bare")
        home.db.cachePut(Answerer.hash(bare), question: "From", fieldType: "text", options: [], answer: "2 weeks after offer", source: "llm:high")
        let res = await answerer.resolve([title, company, from, to, school, major, schoolFrom, schoolTo, attend], job: Fixture.job)
        XCTAssertEqual(res.answers["f"], "03/01/2022", "the job's start, from the profile")
        XCTAssertNil(res.answers["to"], "the current job has no end")
        XCTAssertEqual(res.answers["sf"], "08/01/2015")
        XCTAssertEqual(res.answers["st"], "05/01/2019")
        XCTAssertEqual(res.answers["ca"], "No")
        let alone = await answerer.resolve([bare], job: Fixture.job)
        XCTAssertNil(alone.answers["bare"])
        XCTAssertEqual(alone.unresolved.map(\.id), ["bare"])
        XCTAssertNil(home.db.cacheGet(Answerer.hash(bare)), "the AI's guess is forgotten")
        XCTAssertTrue(model.calls.flatMap { $0 }.isEmpty, "\(model.calls)")
        let code = field("Country code", .combobox, required: false, id: "cc", current: "+1")
        let kept = await answerer.resolve([code], job: Fixture.job)
        XCTAssertNil(kept.answers["cc"], "\(kept.answers)")
    }

    /// Zoho's "Zip/Postal Code" search shows towns for another ZIP until the right one is typed: the on-device AI picked
    /// "Austin, Travis, Texas, United States - 73301" from that first list. The profile's ZIP is typed instead.
    func testTheZipInASearchThatShowsOtherZipsFirst() async throws {
        let home = try TestHome()
        let model = FakeModel([:], default: ("Austin, Travis, Texas, United States - 73301", .high))
        let answerer = Answerer(profile: Fixture.profile, db: home.db, ai: AIService(model: model))
        let zip = field("Zip/Postal Code *", .combobox, ["Ocojala, Chignahuapan, Puebla, Mexico - 73301", "Austin, Travis, Texas, United States - 73301"], id: "z")
        let state = field("State/Province *", .combobox, id: "st")
        home.db.cachePut(Answerer.hash(zip), question: zip.contextLabel, fieldType: "combobox", options: zip.options,
                         answer: "Austin, Travis, Texas, United States - 73301", source: "llm:high")
        let res = await answerer.resolve([zip, state], job: Fixture.job)
        XCTAssertEqual(res.answers["z"], "78701")
        XCTAssertEqual(res.answers["st"], "TX")
        XCTAssertNil(home.db.cacheGet(Answerer.hash(zip)), "the AI's pick is forgotten")
        XCTAssertTrue(model.calls.flatMap { $0 }.isEmpty, "\(model.calls)")
    }

    /// United's form ticks its own sign-up boxes and its "Suffix" got "Sr." from the cloud AI; SoFi's text-message consent
    /// offers only agreement. None of these are an AI's to answer.
    func testSignUpsAndNameSuffixesAreNeverTheAIs() async throws {
        let home = try TestHome()
        let model = FakeModel([:], default: ("Sr.", .high))
        let answerer = Answerer(profile: Fixture.profile, db: home.db, ai: AIService(model: model))
        let mail = field("I agree to receive email communications from United regarding United talent information and opportunities", .checkbox,
                         required: false, id: "em", current: "Yes")
        let texts = field("I agree to receive text message communications from United regarding this application", .checkbox,
                          required: false, id: "tx", current: "Yes")
        let sms = field("I acknowledge that by providing my phone number, I agree to receive text messages from SoFi Technologies in relation to this job application.",
                        .combobox, ["I acknowledge"], id: "sofi")
        let suffix = field("Suffix", required: false, id: "suf")
        let prefix = field("Prefix", required: false, id: "pre")
        home.db.cachePut(Answerer.hash(suffix), question: suffix.contextLabel, fieldType: "text", options: [], answer: "Sr.", source: "cloud:high")
        let res = await answerer.resolve([mail, texts, sms, suffix, prefix], job: Fixture.job)
        XCTAssertEqual(res.answers["em"], "No", "unticked")
        XCTAssertEqual(res.answers["tx"], "No", "unticked")
        XCTAssertNil(res.answers["sofi"])
        XCTAssertEqual(res.unresolved.map(\.id), ["sofi"], "no way to decline: the person says")
        XCTAssertEqual(Set(res.leftBlank.map(\.id)), ["suf", "pre"])
        XCTAssertNil(home.db.cacheGet(Answerer.hash(suffix)), "the AI's guess is forgotten")
        XCTAssertTrue(model.calls.flatMap { $0 }.isEmpty, "\(model.calls)")
        // A box the form requires stays ticked, and so does one the person said to keep.
        let needed = field("I agree to receive text messages about this application", .checkbox, id: "need", current: "Yes")
        home.db.cachePut(Answerer.hash(texts), question: texts.contextLabel, fieldType: "checkbox", options: [], answer: "Yes", source: "user")
        let again = await answerer.resolve([needed, texts], job: Fixture.job)
        XCTAssertNil(again.answers["need"])
        XCTAssertNil(again.answers["tx"])
    }

    /// Tinder's "willing to come into the office … (3 days) according to our hybrid policy?" went to the person though the
    /// profile says which workplaces suit them.
    func testComingIntoTheOfficeFromTheWorkplacePreferences() {
        var p = Fixture.profile
        p.preferences.openToHybrid = true
        p.preferences.openToOnsite = false
        let hybrid = field("Are you willing to come into the office during the week (3 days) according to our hybrid policy?*", .radio, ["Yes", "No"])
        XCTAssertEqual(ProfileRules.answer(p, hybrid), "Yes")
        XCTAssertEqual(ProfileRules.answer(p, field("Are you comfortable working on-site five days a week?", .radio, ["Yes", "No"])), "No")
        XCTAssertEqual(ProfileRules.answer(p, field("Are you open to working in the office 2 days per week?", .select, ["Yes", "No"])), "Yes")
        // Getting there is about where the person lives; an interview isn't the job.
        XCTAssertNil(ProfileRules.answer(p, field("Are you able to commute to our office in Austin, TX?", .radio, ["Yes", "No"])))
        XCTAssertNil(ProfileRules.answer(p, field("Are you available for an in-person interview?", .radio, ["Yes", "No"])))
    }

    /// Taleo's sign-up "User Name" (no spaces allowed): the email the app signs in with, never the full name.
    func testASignUpsUserNameIsTheEmail() {
        let p = Fixture.profile
        XCTAssertEqual(ProfileRules.answer(p, field("User Name . Required", .text)), p.personal.email)
        XCTAssertEqual(ProfileRules.answer(p, field("Username*", .text)), p.personal.email)
        XCTAssertEqual(ProfileRules.answer(p, field("Choose a user ID", .text)), p.personal.email)
        XCTAssertNotEqual(ProfileRules.answer(p, field("GitHub username", .text)), p.personal.email)
        XCTAssertEqual(ProfileRules.answer(p, field("Full name", .text)), p.personal.fullName)
    }

    /// Tenex's referrer box says to write N/A when there's none; the profile says how the person came instead.
    func testNoReferrerWhereTheFormSaysWriteNA() {
        var p = Fixture.profile
        p.preferences.howDidYouHear = "LinkedIn"
        let box = field("If you were referred by a Current Employee, please list their name. If this is not applicable, please list N/A.", .text)
        XCTAssertEqual(ProfileRules.answer(p, box), "N/A")
        XCTAssertEqual(ProfileRules.answer(p, field("Referred by (employee name, or N/A if none)", .text)), "N/A")
        // A plain "who referred you" names someone the app can't know; nor when the person came by a referral.
        XCTAssertNil(ProfileRules.answer(p, field("Who referred you?", .text)))
        p.preferences.howDidYouHear = "Employee referral"
        XCTAssertNil(ProfileRules.answer(p, box))
        p.preferences.howDidYouHear = ""
        XCTAssertNil(ProfileRules.answer(p, box))
    }

    /// "Have you ever been employed by New Relic?" with the company written as one word, and choices that say how.
    func testFormerEmployerQuestionsInOtherWords() {
        let p = Fixture.profile
        XCTAssertEqual(ProfileRules.formerEmployee(p, field("Have you ever been employed by New Relic?", .combobox, ["Yes", "No"]), company: "newrelic"), "No")
        XCTAssertEqual(ProfileRules.formerEmployee(p, field("Are you currently working at New Relic?", .combobox, ["Yes", "No"]), company: "New Relic"), "No")
        XCTAssertEqual(ProfileRules.formerEmployee(p, field("Have you previously been employed at Affirm for any length of time?", .combobox,
            ["I have not previously been employed at Affirm", "I have been employed at Affirm as a full-time employee"]), company: "Affirm"),
            "I have not previously been employed at Affirm")
        XCTAssertEqual(ProfileRules.formerEmployee(p, field("Have you previously worked for Everpure (formerly Pure Storage)?", .combobox,
            ["No", "Yes", "Current Contractor"]), company: "purestorage"), "No")
        XCTAssertEqual(ProfileRules.formerEmployee(p, field("Are you a previous Employee of PayPal or any of its subsidiaries?", .radio,
            ["Yes", "No"]), company: "PayPal"), "No")
        let worked = p.workHistory.first?.company ?? "Acme Corp"
        XCTAssertNil(ProfileRules.formerEmployee(p, field("Have you previously been employed at \(worked)?", .combobox,
            ["I have not previously been employed at \(worked)", "I have been employed at \(worked) as a full-time employee"]), company: worked),
            "someone who did picks the kind themselves")
    }

    /// The profile's "TX" in a list of state names (Infosys left "Alabama", its first choice), and back.
    func testAStateWrittenTheOtherWay() {
        XCTAssertEqual(matchOption("TX", ["Alabama", "Alaska", "Texas", "Utah"]), "Texas")
        XCTAssertEqual(matchOption("TX", ["Select", "TN - Tennessee", "TX - Texas"]), "TX - Texas")
        XCTAssertEqual(matchOption("Texas", ["TN", "TX", "UT"]), "TX")
        XCTAssertEqual(matchOption("VA", ["West Virginia", "Virginia"]), "Virginia")
        XCTAssertNil(matchOption("VA", ["West Virginia", "Wisconsin"]))
    }

    /// SmartRecruiters' screening page is signed by typing the name and the date.
    func testATypedSignatureAndTodaysDate() {
        let p = Fixture.profile
        XCTAssertEqual(ProfileRules.answer(p, field("* Name (Signature Field):", .text)), p.personal.fullName)
        let day = ProfileRules.answer(p, field("* Today's date", .text)) ?? ""
        XCTAssertTrue(Regex(#"^\d\d/\d\d/\d{4}$"#).matches(day), day)
        XCTAssertNil(ProfileRules.answer(p, field("Did you sign a non-compete agreement?", .radio, ["Yes", "No"])))
    }

    /// Boxes for networks the profile keeps no link for are left alone: the on-device AI put the headline in them.
    func testNoAnswerIsMadeUpForOtherNetworks() async throws {
        let home = try TestHome()
        let db = home.db
        db.cachePut(questionHash("Facebook", "text"), question: "Facebook", fieldType: "text", options: [], answer: "Backend", source: "llm:high")
        let answerer = Answerer(profile: Fixture.profile, db: db, ai: nil)
        let fields = [field("Facebook", .text, required: false, id: "f1"), field("X (fka Twitter)", .text, required: false, id: "f2"),
                      field("LinkedIn", .text, required: false, id: "f3")]
        let res = await answerer.resolve(fields, job: JobContext(title: "Engineer", company: "Acme"))
        XCTAssertEqual(res.leftBlank.map(\.label), ["Facebook", "X (fka Twitter)"])
        XCTAssertEqual(res.answers[fields[2].id], "https://www.linkedin.com/in/janedoe")
        XCTAssertNil(db.cacheGet(questionHash("Facebook", "text")), "the made-up answer is forgotten")
    }

    /// A phone number the form turned away as it was written (Infosys takes digits only and says so only by outlining
    /// the box in red): written another way, not the same again.
    func testAPhoneNumberTurnedAwayIsWrittenAnotherWay() async throws {
        XCTAssertEqual(Answerer.otherPhoneFormat("512-555-0142", shown: "512-555-0142"), "5125550142")
        XCTAssertEqual(Answerer.otherPhoneFormat("+1 (512) 555-0142", shown: "+1 (512) 555-0142"), "5125550142")
        XCTAssertEqual(Answerer.otherPhoneFormat("5125550142", shown: "5125550142"), "512-555-0142")
        XCTAssertEqual(Answerer.otherPhoneFormat("+44 20 7946 0958", shown: "+44 20 7946 0958"), "442079460958")
        XCTAssertNil(Answerer.otherPhoneFormat("+44 20 7946 0958", shown: "442079460958"))
        XCTAssertNil(Answerer.otherPhoneFormat("", shown: ""))

        let home = try TestHome()
        var profile = Fixture.profile
        profile.personal.phone = "512-555-0142"
        let answerer = Answerer(profile: profile, db: home.db, ai: nil)
        var phone = field("Phone number", id: "p")
        phone.currentValue = "512-555-0142"
        let again = await answerer.resolve([phone], job: Fixture.job, feedback: ["p": "This field is invalid or required."])
        XCTAssertEqual(again.answers["p"], "5125550142")
        let first = await answerer.resolve([field("Phone number", id: "p")], job: Fixture.job)
        XCTAssertEqual(first.answers["p"], "512-555-0142", "as the profile has it, until the form turns it away")
    }

    /// EchoStar's iCIMS: "Country Code" then a box called only "Number", which got "6" (years of experience).
    func testANumberAfterACountryCodeIsThePhoneNumber() async throws {
        let home = try TestHome()
        var profile = Fixture.profile
        profile.personal.phone = "512-555-0142"
        let answerer = Answerer(profile: profile, db: home.db, ai: nil)
        let res = await answerer.resolve([field("Country Code", .select, ["— Make a Selection —", "(+1) United States", "(+44) United Kingdom"], id: "cc"),
                                          field("Number", id: "n")], job: Fixture.job)
        XCTAssertEqual(res.answers["cc"], "(+1) United States")
        XCTAssertEqual(res.answers["n"], "512-555-0142")
        XCTAssertEqual(Answerer.phoneNumbersAfterCountryCodes([field("Number", id: "n")]).first?.label, "Number", "alone, it could be anything")
    }
}
