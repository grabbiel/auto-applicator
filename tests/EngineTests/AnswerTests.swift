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
        XCTAssertEqual(res.answers, ["f_name": "Jane", "f_cache": "Yes", "f_color": "Blue"])
        XCTAssertEqual(res.sources, ["f_name": "profile", "f_cache": "cache", "f_color": "llm:medium"])
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
}
