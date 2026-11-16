import Foundation

/// What a question is really about, however a form words it: "What gender are you?" and "Please select your
/// gender." are one question. The person answers it once; the answer goes into the profile, so every later form asks
/// it from there.
public enum QuestionTopic: String, CaseIterable, Sendable {
    case pronouns, transgender, sexualOrientation, gender, hispanic, race, veteran, disability
    case howHeard, sponsorship, authorized, relocate, noticePeriod, startDate, over18, salary

    // Checked in this order: "gender pronouns" is about pronouns, "Hispanic or Latino ethnicity" isn't about race.
    private static let patterns: [(QuestionTopic, Regex)] = [
        (.pronouns, Regex(#"pronoun"#)),
        (.transgender, Regex(#"transgender|gender identity (differ|is (the )?same)|identify as trans"#)),
        (.sexualOrientation, Regex(#"sexual orientation"#)),
        (.gender, Regex(#"\bgender\b|\bsex\b(?! offender)|male or female"#)),
        (.hispanic, Regex(#"hispanic|latin[oax]"#)),
        (.race, Regex(#"\brace\b|ethnicit|racial"#)),
        (.veteran, Regex(#"veteran|military (service|status)"#)),
        (.disability, Regex(#"disabilit"#)),
        (.howHeard, Regex(#"how did you (hear|find|learn)|where did you (hear|find|see|learn)|referral source|^source$|how were you referred"#)),
        (.sponsorship, Regex(#"sponsor"#)),
        (.authorized, Regex(#"authori[sz]ed to work|eligible to work|right to work|work authori[sz]ation|legally (able|permitted) to work"#)),
        (.relocate, Regex(#"relocat"#)),
        (.noticePeriod, Regex(#"notice period|how much notice"#)),
        (.startDate, Regex(#"earliest.*start|when can you start|available to start|availability to start|desired start date|^start date$"#)),
        (.over18, Regex(#"(18|eighteen) years|at least 18|over the age of|age of majority"#)),
        (.salary, Regex(#"(desired|expected|target) (salary|compensation|pay)|salary (expectation|requirement)|compensation expectation|^salary$"#)),
    ]

    /// The topic of a question as the inbox shows it ("Education › End date month" is about a school, not a topic).
    public init?(question: String) {
        let q = norm(question)
        guard !q.contains("›") else { return nil }
        guard let hit = Self.patterns.first(where: { $0.1.matches(q) }) else { return nil }
        self = hit.0
    }

    public var title: String {
        switch self {
        case .pronouns: "Pronouns"
        case .transgender: "Transgender"
        case .sexualOrientation: "Sexual orientation"
        case .gender: "Gender"
        case .hispanic: "Hispanic or Latino"
        case .race: "Race or ethnicity"
        case .veteran: "Veteran status"
        case .disability: "Disability status"
        case .howHeard: "How you heard about the job"
        case .sponsorship: "Visa sponsorship"
        case .authorized: "Authorized to work"
        case .relocate: "Willing to relocate"
        case .noticePeriod: "Notice period"
        case .startDate: "Earliest start date"
        case .over18: "Over 18"
        case .salary: "Desired salary"
        }
    }

    static func yesNo(_ answer: String) -> Bool? {
        let a = norm(answer)
        if Regex(#"^(yes|y|true|i am|i do|i will|i have|i can)\b"#).matches(a) { return true }
        if Regex(#"^(no|n|false|i am not|i do not|i don't|i will not|i won't|i have not|i cannot)\b"#).matches(a) { return false }
        return nil
    }

    /// Keeps the answer where the profile holds this topic. Returns false when the answer doesn't fit (e.g. not a
    /// yes or no), leaving the profile as it was.
    @discardableResult
    public func learn(_ answer: String, into p: inout Profile) -> Bool {
        let a = answer.trimmed
        guard !a.isEmpty else { return false }
        switch self {
        case .pronouns: p.eeo.pronouns = a
        case .transgender: return false  // the profile doesn't keep it; the saved answer is reused for the same wording
        case .sexualOrientation: p.eeo.sexualOrientation = a
        case .gender: p.eeo.gender = a
        case .hispanic: p.eeo.hispanicOrLatino = a
        case .race: p.eeo.ethnicity = a
        case .veteran: p.eeo.veteranStatus = a
        case .disability: p.eeo.disabilityStatus = a
        case .howHeard: p.preferences.howDidYouHear = a
        case .noticePeriod: p.preferences.noticePeriod = a
        case .startDate: p.preferences.earliestStartDate = a
        case .sponsorship:
            guard let v = Self.yesNo(a) else { return false }
            p.workAuthorization.requiresSponsorship = v
        case .authorized:
            guard let v = Self.yesNo(a) else { return false }
            p.workAuthorization.authorizedToWork = v
        case .relocate:
            guard let v = Self.yesNo(a) else { return false }
            p.preferences.willingToRelocate = v
        case .over18:
            guard let v = Self.yesNo(a) else { return false }
            p.preferences.over18 = v
        case .salary:
            guard let n = Regex(#"\d[\d,]*"#, []).allMatches(a).first.flatMap({ Int($0.replacingOccurrences(of: ",", with: "")) }) else { return false }
            p.compensation.desiredBase = Regex(#"\d\s*k\b"#).matches(a) && n < 1000 ? n * 1000 : n
        }
        return true
    }
}

/// Questions waiting in the inbox that are the same question in other words: the same topic, or almost the same
/// wording.
public enum QuestionGroups {
    public static func sameQuestion(_ a: String, _ b: String) -> Bool {
        if let t = QuestionTopic(question: a), t == QuestionTopic(question: b) { return true }
        return Difflib.ratio(norm(a), norm(b)) >= 0.85
    }

    /// The waiting questions grouped: the first of each group stands for the rest.
    public static func group(_ pending: [PendingQuestion]) -> [(PendingQuestion, [PendingQuestion])] {
        var groups: [(PendingQuestion, [PendingQuestion])] = []
        for q in pending {
            if let i = groups.firstIndex(where: { sameQuestion($0.0.question, q.question) }) {
                groups[i].1.append(q)
            } else {
                groups.append((q, []))
            }
        }
        return groups
    }

    /// The person can't answer a waiting question: it and the waiting questions that ask the same thing are
    /// remembered as such, and the jobs waiting on them are skipped. Returns how many questions that was.
    @discardableResult
    public static func decline(_ q: PendingQuestion, db: Database) -> Int {
        let others = db.listPending().filter { $0.hash != q.hash && sameQuestion(q.question, $0.question) }
        db.declinePending(q.hash)
        others.forEach { db.declinePending($0.hash) }
        return 1 + others.count
    }

    /// Saves the person's answer to a waiting question for every future form, learns it into the profile when the
    /// profile keeps that kind of answer, and answers the other waiting questions that ask the same thing (where the
    /// answer fits their choices). Returns how many questions were answered.
    @discardableResult
    public static func answer(_ q: PendingQuestion, with answer: String, db: Database, profile: inout Profile) -> Int {
        let answer = answer.trimmed
        guard !answer.isEmpty else { return 0 }
        db.resolvePending(q.hash, answer: answer)
        var answered = 1
        if let topic = QuestionTopic(question: q.question) { topic.learn(answer, into: &profile) }
        if let skill = Memory.learnedSkill(question: q.question, answer: answer) { profile.experienceYears[skill.skill] = skill.years }
        for other in db.listPending() where other.hash != q.hash && sameQuestion(q.question, other.question) {
            let spec = FieldSpec(id: "q", label: other.question, type: FieldSpec.FieldType(rawValue: other.fieldType) ?? .text, options: other.options)
            if let fitted = coerceAnswer(spec, answer) {
                db.resolvePending(other.hash, answer: fitted)
                answered += 1
            }
        }
        return answered
    }
}
