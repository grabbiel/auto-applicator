import Foundation

public enum Confidence: String, Sendable, CaseIterable {
    case high, medium, low
}

public struct FieldAnswer: Equatable, Sendable {
    public var evidence: String
    public var answer: String
    public var confidence: Confidence

    public init(evidence: String, answer: String, confidence: Confidence) {
        self.evidence = evidence
        self.answer = answer
        self.confidence = confidence
    }
}

/// What the answer engine needs from the AI (the real one is `AIService`; tests use a stand-in).
public protocol FormAnswering: Sendable {
    func answerFields(_ fields: [FieldSpec], profileText: String, job: JobContext, feedback: [String: String],
                      memories: [String]) async throws -> [String: FieldAnswer]
    /// The longest list of options (in characters) it can be shown at once.
    var maxOptionChars: Int { get }
}

public extension FormAnswering {
    var maxOptionChars: Int { .max }
}

public struct Resolution: Sendable {
    public var answers: [String: String] = [:]
    /// Required fields without a confident answer: the job is skipped and the question goes to the user.
    public var unresolved: [FieldSpec] = []
    /// Optional fields without a confident answer: left empty.
    public var leftBlank: [FieldSpec] = []
    /// Required fields the person said they can't answer: the job is skipped for good.
    public var declined: [FieldSpec] = []
    /// Optional questions neither AI could answer (also in `leftBlank`): what the person is asked when the form won't
    /// go on without them.
    public var unanswered: [FieldSpec] = []
    /// Where each answer came from: "cache", "profile", "memory", "llm:high" / "llm:medium" (the on-device AI) or
    /// "cloud:high" / "cloud:medium" (the cloud AI), or "rule" ("N/A" for an "If yes, …" box after a No).
    public var sources: [String: String] = [:]
    public var blocked: Bool { !unresolved.isEmpty || !declined.isEmpty }
}

/// Answers form fields: answers the user gave before → the profile → similar questions the user answered → the
/// on-device AI, which must cite the profile → for what it couldn't answer, the stronger cloud AI (on runs in the cloud
/// browser), under the same rules. An answer neither AI is confident about is never submitted: if the field is
/// required, the application is skipped and the question is saved for the user to answer once.
public final class Answerer: @unchecked Sendable {
    public let profile: Profile
    public let db: Database
    let ai: FormAnswering?
    /// The cloud AI, for the questions `ai` couldn't answer (nil when the run isn't in the cloud browser).
    let helper: FormAnswering?
    public let memory: Memory
    let batchSize: Int
    public let profileText: String
    /// The profile for the cloud AI: without the email address and phone number, which its questions never need (the
    /// profile's rules answer those).
    let cloudProfileText: String
    private let profileTokens: Set<String>
    /// Questions the cloud AI may still be asked this run: it's for the few the on-device AI misses.
    private var helperBudget: Int
    private var helperDown = false

    public init(profile: Profile, db: Database, ai: FormAnswering?, helper: FormAnswering? = nil, memory: Memory? = nil, batchSize: Int = 6,
                helperBudget: Int = 60) {
        self.profile = profile
        self.db = db
        self.ai = ai
        self.helper = helper
        self.memory = memory ?? Memory(db: db)
        self.batchSize = max(1, batchSize)
        self.helperBudget = helperBudget
        profileText = ProfileText.render(profile)
        cloudProfileText = profileText.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("email:") && !$0.hasPrefix("phone:") }.joined(separator: "\n")
        profileTokens = contentTokens(profileText)
    }

    private func cacheable(_ f: FieldSpec, _ job: JobContext) -> Bool {
        if f.type == .textarea || f.type == .file { return false }
        if Self.entryDetail(f) { return false }  // true of one job or school on one form, not of the next
        if !f.plainLabel.contains(where: \.isLetter) { return false }
        return job.company.isEmpty || !norm(f.label).contains(norm(job.company))
    }

    /// A detail of one job or school in a list of them ("Location", "I currently work here", "End date" under Work
    /// experience): its answer depends on the entry, so a saved answer from another form doesn't fit it.
    static func entryDetail(_ f: FieldSpec) -> Bool {
        let label = norm(f.plainLabel)
        if currentJobLabel.matches(label) { return true }
        if f.section == "Education" && ProfileRules.ownContactLabel.matches(label) { return false }
        return ["Work experience", "Education"].contains(f.section) && FieldSpec.ambiguous.matches(label)
    }

    static let currentJobLabel = Regex(#"^(i )?(currently|still) (work|working|employed)( here| there)?$|^i (currently )?work here$|^current(ly)? (job|employer|position|role)$"#)

    /// "I currently work here" in one of several jobs on the form (Blue Yonder's, filled from the resume): that job's
    /// answer, from the company its entry names. A company the profile doesn't have as a current job is "No".
    static func currentJob(_ f: FieldSpec, in fields: [FieldSpec], _ p: Profile, answers: [String: String] = [:]) -> String? {
        guard [.checkbox, .radio, .select, .combobox].contains(f.type), currentJobLabel.matches(norm(f.plainLabel)),
              let current = entryIsCurrent(f, in: fields, p, answers: answers) else { return nil }
        return ProfileRules.yn(current)
    }

    /// Whether the job a work-experience entry's box belongs to is the person's current one, from the company the
    /// entry names (as the form shows it, or as answered this round). Nil when the entry names none.
    static func entryIsCurrent(_ f: FieldSpec, in fields: [FieldSpec], _ p: Profile, answers: [String: String] = [:]) -> Bool? {
        guard f.section != "Education", let i = fields.firstIndex(where: { $0.id == f.id }) else { return nil }
        let companyLabel = Regex(#"^(company|employer|organi[sz]ation)( name)?$"#)
        let schoolLabel = Regex(#"^(school|institution|university|college)( name)?$|^degree$|^(field of study|major|discipline)$"#)
        // The entry's own company, not one above a school's entry (SAP's school "To" under the current job).
        guard let box = fields[..<i].reversed().prefix(8).first(where: { companyLabel.matches(norm($0.plainLabel)) || schoolLabel.matches(norm($0.plainLabel)) }),
              companyLabel.matches(norm(box.plainLabel)) else { return nil }
        let shown = box.currentValue.trimmed.isEmpty ? (answers[box.id] ?? "") : box.currentValue
        guard !shown.trimmed.isEmpty else { return nil }
        let named = norm(shown)
        let role = p.workHistory.first {
            let c = norm($0.company)
            return !c.isEmpty && (c == named || named.contains(c) || c.contains(named))
        }
        return role?.isCurrent ?? false
    }

    /// When a job ended: none for the current one, whose "Current role" box says so (Greenhouse's employment block on
    /// Lyft's and Coinbase's forms asks for an end month and year beside it).
    static let endDateLabel = Regex(#"^(end|finish|to)( date)?( (month|year))?$|^end (month|year)$|^(date|month|year) (ended|to|left)$"#)

    /// What a question asks, from its choices alone: the U.S. disability and veteran self-identification forms.
    static func questionFromOptions(_ options: [String]) -> String? {
        let all = options.map(norm).joined(separator: " | ")
        if Regex(#"\b(i )?(have|had) a disability\b|\b(do not|don'?t) have a disability\b"#).matches(all) { return "Disability status" }
        if Regex(#"\bveteran\b"#).matches(all) { return "Veteran status" }
        return nil
    }

    /// A name from the page's code rather than a question: one word in camelCase or with digits or underscores.
    static let codeLabel = Regex(#"^[a-z]+[A-Z][A-Za-z0-9_]*$|^[A-Za-z]+[_0-9][A-Za-z0-9_]*$"#, [])

    static let placeholderLabel = Regex(#"^((please )?(select|choose)( one| an option| an answer)?|search|-+|textbox|combobox|dropdown|type here)$"#)

    /// The saved-answer key: the question with its section when the label alone is ambiguous.
    static func hash(_ f: FieldSpec) -> String { questionHash(f.contextLabel, f.type.rawValue, f.options) }

    /// An answer straight from the profile: its rules, a title from its gender, its skills for a skills box.
    func fromProfile(_ f: FieldSpec, job: JobContext) -> String? {
        if let ruled = coerceAnswer(f, ProfileRules.answer(profile, f)) { return ruled }
        if let title = ProfileRules.honorific(profile, f) { return title }
        if let worked = coerceAnswer(f, ProfileRules.formerEmployee(profile, f, company: job.company)) { return worked }
        if [.text, .combobox].contains(f.type) || f.maxChoices > 1, ProfileRules.skillsLabel.matches(norm(f.label)) {
            return ProfileRules.skills(profile, job: job, limit: f.maxChoices > 1 ? f.maxChoices : 8)
        }
        return nil
    }

    /// A text box holding something that belongs elsewhere: a name prefix or suffix box with no prefix or suffix in it,
    /// or a second address line that repeats the street.
    static func misfiled(_ f: FieldSpec, _ p: Profile) -> Bool {
        let label = norm(f.label), value = norm(f.currentValue).replacingOccurrences(of: ".", with: "").trimmed
        if Regex(#"^(name )?prefix$|^salutation$"#).matches(label) {
            return !["mr", "mrs", "ms", "miss", "mx", "dr", "prof", "rev"].contains(value)
        }
        if Regex(#"^(name )?suffix$"#).matches(label) {
            return !["jr", "sr", "ii", "iii", "iv", "v", "phd", "md", "esq", "dds", "cpa", "pe"].contains(value)
        }
        // The person's city, state and country saved for Toyota's "County*": no county.
        if Regex(#"^(county|county of residence|parish|borough)$"#).matches(label) {
            let city = norm(p.personal.address.city)
            return value.contains(",") || (!city.isEmpty && value == city)
        }
        if ProfileRules.addressLine2.matches(label) {
            let street = p.personal.address.street.trimmed
            if !street.isEmpty && norm(street) == norm(f.currentValue) { return true }
            // The person's city written there (Adobe's and Infosys's "Austin, TX, United States"): no apartment or suite.
            let city = norm(p.personal.address.city)
            return !city.isEmpty && Regex("\\b" + NSRegularExpression.escapedPattern(for: city) + "\\b").matches(norm(f.currentValue))
                && !f.currentValue.contains(where: \.isNumber) && !Regex(#"\b(apt|apartment|suite|ste|unit|floor|fl|building|bldg|room|po box)\b|#"#).matches(norm(f.currentValue))
        }
        return false
    }

    /// A whole date for boxes that each take one part of it (Rippling's "Earliest available start date" as month, day
    /// and year): each box its part.
    /// The last touches on a form's answers: "N/A" in each "If yes, …" box after a No, whatever else matched it (the
    /// email for Lockheed's "If you answered "Yes" and are a former LM employee: … you must have had an LM email
    /// address …"), then dates split into their parts.
    static func finish(_ res: Resolution, _ fields: [FieldSpec]) -> Resolution {
        var res = res
        for f in fields where res.answers[f.id] != nil {
            guard let na = notApplicableFollowUp(f, in: fields, res), res.answers[f.id] != na else { continue }
            res.answers[f.id] = na
            res.sources[f.id] = "rule"
        }
        return splitDates(res, fields)
    }

    static func splitDates(_ res: Resolution, _ fields: [FieldSpec]) -> Resolution {
        var res = res
        for f in fields {
            guard let answer = res.answers[f.id], let part = Regex(#"\((month|day|year)\)\W*$"#).firstGroups(f.label.lowercased())?[1] else { continue }
            let a = answer.trimmed
            var parts: (m: Int, d: Int, y: Int)?
            if let g = Regex(#"^(\d{1,2})/(\d{1,2})/(\d{4})$"#).firstGroups(a), let m = Int(g[1] ?? ""), let d = Int(g[2] ?? ""), let y = Int(g[3] ?? "") {
                parts = f.placeholder.lowercased().hasPrefix("dd") ? (d, m, y) : (m, d, y)
            } else if let g = Regex(#"^(\d{4})-(\d{1,2})-(\d{1,2})$"#).firstGroups(a), let y = Int(g[1] ?? ""), let m = Int(g[2] ?? ""), let d = Int(g[3] ?? "") {
                parts = (m, d, y)
            }
            guard let parts else { continue }
            res.answers[f.id] = part == "year" ? String(parts.y) : String(format: "%02d", part == "month" ? parts.m : parts.d)
        }
        return res
    }

    /// An answer this app would empty again once it's in the box (the city saved for Adobe's "Address Line 2"): filling
    /// it would only start a fill-and-empty loop.
    func misplaced(_ f: FieldSpec, _ answer: String) -> Bool {
        guard f.type == .text else { return false }
        var shown = f
        shown.currentValue = answer
        return Self.misfiled(shown, profile)
    }

    /// The box for the person's own phone number.
    static let phoneLabel = Regex(#"^(your |mobile |cell |home |primary |contact )?(phone|telephone|mobile|cell)( phone)?( number| no\.?)?( \d)?$"#)

    /// The person's phone number written another way than `shown` (what the box holds now), for a form that turned it
    /// away: with dashes, spaces or brackets in it, the digits alone (Infosys's check); as digits alone, 512-555-0142.
    /// Nil without a number in the profile, or with no other way to write it.
    static func otherPhoneFormat(_ phone: String, shown: String) -> String? {
        var digits = phone.filter(\.isNumber)
        guard digits.count >= 7 else { return nil }
        // A US or Canadian number without its country code (+1), as the form's own country list or format has it.
        if digits.count == 11, digits.hasPrefix("1"), !phone.trimmed.hasPrefix("+") || phone.trimmed.hasPrefix("+1") { digits.removeFirst() }
        let now = shown.trimmed
        if now.isEmpty || now.contains(where: { !$0.isNumber }) { return now == digits ? nil : digits }
        guard digits.count == 10 else { return nil }
        return "\(digits.prefix(3))-\(digits.dropFirst(3).prefix(3))-\(digits.suffix(4))"
    }

    /// The same answer written another way: "(512) 555-0142" and "5125550142", "OR - Oregon" and "Oregon".
    static func sameAnswer(_ mine: String, _ current: String) -> Bool {
        // A link is the same only in the same form: sites turn away "linkedin.com/in/…" without https://.
        if Regex(#"^(https?://|www\.)|\.(com|org|net|io|dev|me)(/|$)"#).matches(mine.trimmed) {
            return mine.trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) ==
                current.trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        let a = norm(mine).filter { $0.isLetter || $0.isNumber }, b = norm(current).filter { $0.isLetter || $0.isNumber }
        let da = mine.filter(\.isNumber), db = current.filter(\.isNumber)
        // A phone number: the same with the country code in front ("+1 512…" for "512…"), never one missing digits
        // (Workable read a US number's "51" as Peru's code and kept "25550142").
        if da.count >= 7, db.count >= 7, a == da, b == db {
            return db.hasSuffix(da) || (mine.trimmed.hasPrefix("+") && da.hasSuffix(db) && da.count - db.count <= 3)
        }
        if a == b || (min(a.count, b.count) >= 4 && (a.contains(b) || b.contains(a))) { return true }
        if da.count >= 7, db.count >= 7, da.hasSuffix(db) || db.hasSuffix(da) { return true }
        return matchOption(mine, [current]) != nil
    }

    /// A job's or school's dates on a page that gives its entries no heading (SmartRecruiters' "Title", "Company",
    /// "From", "To", then "Institution", "Major", "Degree", "From", "To", "I currently attend"): the entry they belong
    /// to, from the nearest box above (else just below) that names a job or a school.
    static func entrySections(_ fields: [FieldSpec]) -> [FieldSpec] {
        let entryOnly = Regex(#"^(start|end|from|to)( date)?( (month|year|date))?$|^i (currently )?(work|attend) here$|^i currently (work|attend)$|^currently (working|attending)( here)?$"#)
        let work = Regex(#"^((job |position )?title|company( name)?|employer( name)?)$"#)
        let school = Regex(#"^(school|institution|university|college)( name)?$|^degree$|^(field of study|major|discipline)$"#)
        var out = fields
        for (i, f) in fields.enumerated() where f.section.isEmpty && entryOnly.matches(norm(f.plainLabel)) {
            let near = Array(fields[max(0, i - 8)..<i].reversed()) + Array(fields[min(fields.count, i + 1)..<min(fields.count, i + 5)])
            for g in near where g.section.isEmpty {
                let label = norm(g.plainLabel)
                if work.matches(label) && !ProfileRules.isHonorific(g) { out[i].section = "Work experience"; break }
                if school.matches(label) { out[i].section = "Education"; break }
            }
        }
        return out
    }

    /// "Number" just after a phone's country code is the phone number (EchoStar's iCIMS sign-in: "Country Code",
    /// "Number"). Taken alone, it was answered as "how many" with the person's years of experience.
    static func phoneNumbersAfterCountryCodes(_ fields: [FieldSpec]) -> [FieldSpec] {
        let bare = Regex(#"^(number|no\.?|#|digits)$"#)
        let code = Regex(ProfileRules.phoneCountryLabel + #"|country (phone )?code|phone (country )?code|dialing code"#)
        var out = fields
        for i in out.indices.dropFirst() where bare.matches(norm(out[i].plainLabel)) && code.matches(norm(out[i - 1].plainLabel)) {
            out[i].label = "Phone number"
        }
        return out
    }

    public func resolve(_ fields: [FieldSpec], job: JobContext, feedback: [String: String] = [:]) async -> Resolution {
        let fields = Self.entrySections(Self.phoneNumbersAfterCountryCodes(fields))
        var res = Resolution()
        var todo: [FieldSpec] = []
        func park(_ f: FieldSpec) { if f.required { res.unresolved.append(f) } else { res.leftBlank.append(f) } }

        for var f in fields where f.type != .file {
            // A question named only "Choose One" (the disability form on Jobvite) or by the page's code (Fiserv's
            // "jsqData") whose choices say what it asks.
            if Self.placeholderLabel.matches(norm(f.label)) || Self.codeLabel.matches(f.label.trimmed) || !f.plainLabel.contains(where: \.isLetter),
               let named = Self.questionFromOptions(f.options) {
                f.label = named
            }
            let fb = feedback[f.id]
            // The person's phone number turned away as it's written (Infosys takes digits only, without a word: it outlines
            // "512-555-0142" in red): written another way.
            if fb != nil, f.type == .text, Self.phoneLabel.matches(norm(f.plainLabel)), !["References", "Emergency contact", "Referral"].contains(f.section),
               let other = Self.otherPhoneFormat(profile.personal.phone, shown: f.currentValue) {
                res.answers[f.id] = other
                res.sources[f.id] = "profile"
                continue
            }
            // The person's own details beat what a site read off the resume: Workday's "linkedin.com/in/…" (which it then
            // turns away), Blue Yonder's "Peru" for Country (which made the US phone number invalid).
            if !f.currentValue.isEmpty, !["Work experience", "Education", "References", "Emergency contact", "Referral"].contains(f.section),
               ProfileRules.ownDetailsLabel.matches(norm(f.label)), let mine = fromProfile(f, job: job), !Self.sameAnswer(mine, f.currentValue) {
                res.answers[f.id] = mine
                res.sources[f.id] = "profile"
                continue
            }
            // A middle name the site read off the resume that is really the last (or first) name (Paylocity copied the last name there):
            // emptied; the profile has no middle name.
            if ProfileRules.middleLabel.matches(norm(f.label)), f.type == .text, !f.currentValue.trimmed.isEmpty,
               [profile.personal.lastName, profile.personal.firstName].contains(where: { !$0.trimmed.isEmpty && norm($0) == norm(f.currentValue) }) {
                res.answers[f.id] = ""
                res.sources[f.id] = "profile"
                continue
            }
            // Other boxes the site filled wrongly from the resume (United's Phenom form: "Jane" in Prefix, the email in
            // Suffix, the street again in "Street Address (line 2)"): emptied.
            if f.type == .text, !f.currentValue.trimmed.isEmpty, Self.misfiled(f, profile) {
                res.answers[f.id] = ""
                res.sources[f.id] = "profile"
                continue
            }
            // A sign-up box the site ticked itself (United's "I agree to receive email communications…" and "…text message
            // communications…"): unticked, unless the form requires it or the person said to keep it.
            if f.type == .checkbox, !f.required, fb == nil, norm(f.currentValue) == "yes", ProfileRules.signup.matches(norm(f.label)),
               !["user", "edited"].contains(db.cacheSource(Self.hash(f)) ?? "") {
                res.answers[f.id] = "No"
                res.sources[f.id] = "profile"
                continue
            }
            if fb == nil && !f.currentValue.isEmpty && f.error.isEmpty { continue }  // already filled (e.g. by LinkedIn)
            // Boxes that only sign the person up (Dropbox's "Dropbox Talent Community" under "Application Questions"):
            // none ticked, unless the form requires one.
            if f.type == .checkboxGroup, !f.required, !f.options.isEmpty, f.options.allSatisfy({ ProfileRules.signup.matches(norm($0)) }) {
                res.leftBlank.append(f)
                continue
            }
            // A list with nothing to choose yet (Conduent's "State / Province" shows only "-" until a country is chosen):
            // answered once it has drawn its choices, not put to the person, who couldn't pick one either.
            if f.type == .select, !f.options.isEmpty, !f.options.contains(where: { !isPlaceholderOption($0) && !$0.trimmed.isEmpty }) {
                res.leftBlank.append(f)
                continue
            }
            // A box named only by its placeholder ("Select"): its question wasn't found, and any answer would be a guess
            // at a question nobody read (Rippling's lists all got "Yes", "please pick the opposite of Yes" too).
            if Self.placeholderLabel.matches(norm(f.label)) {
                park(f)
                continue
            }
            // A box with no words at all (Dover's, whose labels the page drew apart from them): nobody read its question,
            // so neither a saved answer nor the AI's guess fits it ("6" went into every one).
            if !f.plainLabel.contains(where: \.isLetter) {
                if let source = db.cacheSource(Self.hash(f)), source != "user", source != "edited" { db.cacheDelete(Self.hash(f)) }
                if f.required { park(f) } else { res.leftBlank.append(f) }
                continue
            }
            let qh = Self.hash(f)
            // The letters in a picture that prove a person is there (Zoho's "Type below image text", which the AI once
            // answered "Backend"): never typed by the app, nor asked of the person ahead of time. The run stops at the
            // form's security check instead.
            if ProfileRules.pictureCheck.matches(norm(f.label)) {
                if db.cacheSource(qh) != nil { db.cacheDelete(qh) }
                res.leftBlank.append(f)
                continue
            }
            if db.cacheSource(qh) == "declined" {
                if f.required { res.declined.append(f) } else { res.leftBlank.append(f) }
                continue
            }
            // A GPA the profile doesn't have (both AIs answered "3.0" for Beli's "What was your undergraduate GPA?",
            // and "Yes" for "a cumulative GPA of 3.0 or higher?"): never made up.
            if ProfileRules.gpaLabel.matches(norm(f.label)), profile.education.allSatisfy({ $0.gpa.trimmed.isEmpty }),
               !["user", "edited"].contains(db.cacheSource(qh) ?? "") {
                if db.cacheSource(qh) != nil { db.cacheDelete(qh) }
                park(f)
                continue
            }
            if ProfileRules.otherNetworkLabel.matches(norm(f.label)), !["user", "edited"].contains(db.cacheSource(qh) ?? "") {
                if db.cacheSource(qh) != nil { db.cacheDelete(qh) }  // what the AI made up before
                park(f)
                continue
            }
            // What the profile says beats an answer the AI saved before (TCS's skills as "Java (1); C# (1); …"); the
            // person's own answers still come first.
            let personal = ["user", "edited"].contains(db.cacheSource(qh) ?? "")
            // Who the person is (gender, pronouns, race, veteran or disability status…): only ever what they said
            // themselves, never an AI's guess (NMI's lists got "Woman" and "White or European" for someone who declines
            // to say; Dropbox's pronouns got "She / Her / Hers", read off a first name).
            if Self.selfIdentification(f), !personal {
                if db.cacheSource(qh) != nil { db.cacheDelete(qh) }
                if let given = fromProfile(f, job: job), fb == nil || f.currentValue.trimmed.isEmpty || !Self.sameAnswer(given, f.currentValue) {
                    res.answers[f.id] = given
                    res.sources[f.id] = "profile"
                } else {
                    park(f)
                }
                continue
            }
            // Also when the form says a box it was given is empty (it lost the answer when the page redrew, Serco's
            // "Mobile Phone"): the profile's answer again, not a question for the person.
            if ProfileRules.addressLine2.matches(norm(f.label)), f.type == .text, !personal, db.cacheGet(qh).map({ misplaced(f, $0) }) ?? true {
                if db.cacheSource(qh) != nil { db.cacheDelete(qh) }  // the city saved there before (Adobe's)
                park(f)  // the profile has one street line (Infosys's "Address 2" got the city)
                continue
            }
            if f.currentValue.trimmed.isEmpty, let given = coerceAnswer(f, Self.currentJob(f, in: fields, profile, answers: res.answers)) {
                res.answers[f.id] = given
                res.sources[f.id] = "profile"
                continue
            }
            // The place under a kind that doesn't name it (Toyota's "Source" under "Job Board" lists Dice and Indeed):
            // the next kind instead ("Social Media"), and this list again once it has redrawn.
            if f.currentValue.trimmed.isEmpty, !f.options.isEmpty, ProfileRules.subSourceLabel.matches(norm(f.plainLabel)),
               let source = ProfileRules.nonEmpty(profile.preferences.howDidYouHear), ProfileRules.sourceOption(source, f.options) == nil,
               let i = fields.firstIndex(where: { $0.id == f.id }),
               let parent = fields[max(0, i - 3)..<i].last(where: { ProfileRules.hearLabel.matches(norm($0.plainLabel)) }),
               let next = ProfileRules.nextSourceKind(after: res.answers[parent.id] ?? parent.currentValue, parent.options, source: source) {
                res.answers[parent.id] = next
                res.sources[parent.id] = "profile"
                res.leftBlank.append(f)
                continue
            }
            if f.currentValue.trimmed.isEmpty, Self.endDateLabel.matches(norm(f.plainLabel)),
               Self.entryIsCurrent(f, in: fields, profile, answers: res.answers) == true {
                res.leftBlank.append(f)
                continue
            }
            if fb == nil || f.currentValue.trimmed.isEmpty, !personal, let given = fromProfile(f, job: job) {
                if db.cacheSource(qh) != nil, db.cacheGet(qh) != given { db.cacheDelete(qh) }  // a guess the profile corrects
                res.answers[f.id] = given
                res.sources[f.id] = "profile"
                continue
            }
            // A sign-up or text-message consent with no way to decline it (SoFi's required "I agree to receive text
            // messages…", whose choices only agree): the person's call, never an AI's.
            if !personal, [.checkbox, .radio, .select, .combobox, .checkboxGroup].contains(f.type), ProfileRules.signup.matches(norm(f.label)) {
                if db.cacheSource(qh) != nil { db.cacheDelete(qh) }
                park(f)
                continue
            }
            // A bare "From" or "To" that belongs to nothing the page names: no question an AI can answer (the on-device
            // AI saved "2 weeks after offer" for a job's "From").
            if !personal, f.section.isEmpty, Regex(#"^(from|to)( date)?$"#).matches(norm(f.plainLabel)) {
                if db.cacheSource(qh) != nil { db.cacheDelete(qh) }
                park(f)
                continue
            }
            // Pay in other terms than the profile's (a month's take-home pay in lei): the person's to say, not converted.
            if !personal, ProfileRules.salaryInOtherTerms(f, profile) {
                if db.cacheSource(qh) != nil { db.cacheDelete(qh) }
                park(f)
                continue
            }
            // A name prefix or suffix the profile doesn't have (the cloud AI put "Sr." in United's "Suffix"): never guessed.
            if !personal, ProfileRules.nameAffixLabel.matches(norm(f.label)) {
                if db.cacheSource(qh) != nil { db.cacheDelete(qh) }
                park(f)
                continue
            }
            // The person's own city, state or ZIP in a search box whose first choices don't hold it (Zoho's "Zip/Postal
            // Code" shows Mexican towns for 73301 until 78701 is typed): the profile's value, typed and picked from what
            // the search finds; never an AI's pick from that first list.
            if f.type == .combobox, !personal, f.currentValue.trimmed.isEmpty,
               Regex(#"^(zip|postal)( ?/ ?postal)?( code)?$|^city$|^(state|province)( ?/ ?province)?$"#).matches(norm(f.plainLabel)),
               let raw = ProfileRules.nonEmpty(ProfileRules.answer(profile, f) ?? "") {
                if db.cacheSource(qh) != nil { db.cacheDelete(qh) }
                res.answers[f.id] = raw
                res.sources[f.id] = "profile"
                continue
            }
            if fb != nil && !f.currentValue.isEmpty {
                // The form rejected the value we entered: forget it and ask the AI with the error message.
                if let source = db.cacheSource(qh), source != "user", source != "edited" { db.cacheDelete(qh) }
                todo.append(f)
                continue
            }
            if Self.entryDetail(f), !personal, db.cacheSource(qh) != nil {
                db.cacheDelete(qh)  // an AI's answer for another form's job or school (Blue Yonder's school "Location" got a degree)
            }
            if let cached = coerceAnswer(f, db.cacheGet(qh)) {
                // An AI's saved answer where the profile now answers itself (the AI's "Bachelor's" for "Are you currently
                // pursuing a Bachelor's or Master's degree?", saved before the profile's finished schools answered it):
                // the profile's, and the AI's is forgotten.
                if let source = db.cacheSource(qh), source.hasPrefix("llm:") || source.hasPrefix("cloud:"),
                   let given = fromProfile(f, job: job), !Self.sameAnswer(given, cached) {
                    db.cacheDelete(qh)
                    res.answers[f.id] = given
                    res.sources[f.id] = "profile"
                    continue
                }
                if plausible(f, cached) && !misplaced(f, cached) {
                    res.answers[f.id] = cached
                    res.sources[f.id] = "cache"
                    continue
                }
                // A wrong answer the AI saved earlier (e.g. a salary for a ZIP code): forget it.
                if let source = db.cacheSource(qh), source != "user", source != "edited" { db.cacheDelete(qh) }
            }
            if let given = fromProfile(f, job: job) {
                res.answers[f.id] = given
                res.sources[f.id] = "profile"
                continue
            }
            if ProfileRules.isHonorific(f) {
                park(f)  // "Mr." or "Ms.": only the person can say (never guessed from a name)
                continue
            }
            if ProfileRules.middleLabel.matches(norm(f.label)) {
                park(f)  // the profile has no middle name: never guessed (TCS's "M.I." got the full name)
                continue
            }
            if ProfileRules.extensionLabel.matches(norm(f.label)) && !f.required {
                res.leftBlank.append(f)  // no extension in the profile (Blue Yonder's got the whole number)
                continue
            }
            if ProfileRules.formerJobDetail.matches(norm(f.label)) && !f.required
                && ProfileRules.formerEmployee(profile, FieldSpec(id: "", label: "have you previously worked for \(job.company)", type: .radio,
                                                                  options: ["Yes", "No"]), company: job.company) != "Yes" {
                res.leftBlank.append(f)  // "Who was your Manager?" here: for former employees only
                continue
            }
            if ["References", "Emergency contact", "Referral"].contains(f.section) && FieldSpec.ambiguous.matches(norm(f.label)) {
                park(f)  // another person's name, phone or email: only the person can say
                continue
            }
            // A detail of a job or school the profile doesn't have (a GPA, a school's city): never made up. A list's
            // choice for what the profile does have (its degree among "Bachelor's Degree - Completed", …) is the AI's.
            if Self.entryDetail(f) && (!f.required || f.options.isEmpty) {
                if f.required { park(f) } else { res.leftBlank.append(f) }
                continue
            }
            if let remembered = memory.similarAnswer(for: f), plausible(f, remembered), !misplaced(f, remembered) {
                res.answers[f.id] = remembered
                res.sources[f.id] = "memory"
                continue
            }
            if neverGuess.matches(norm(f.label)) {
                park(f)
                continue
            }
            if [.number, .text, .select, .radio, .combobox].contains(f.type) && asksYearsOfSkill(f) {
                park(f)  // "Years of X" with X missing from the profile: never let the AI guess a number
                continue
            }
            todo.append(f)
        }

        guard !todo.isEmpty else { return Self.finish(res, fields) }
        var missed = todo
        if let ai {
            // A list too long for the on-device AI (Fiserv's 300 fields of study) goes straight to the cloud AI.
            let tooLong = helper == nil || helperDown ? [] : todo.filter { $0.options.joined(separator: ", ").count > ai.maxOptionChars }
            let mine = todo.filter { f in !tooLong.contains { $0.id == f.id } }
            missed = await ask(ai, mine, batchSize: batchSize, source: "llm", profileText: profileText, job: job, feedback: feedback, into: &res)
            missed = tooLong + missed
        }
        if !missed.isEmpty, let helper, !helperDown, helperBudget > 0, !Task.isCancelled {
            let asked = Array(missed.prefix(helperBudget))
            helperBudget -= asked.count
            Log.info("Asking the cloud AI about \(asked.count) question(s) the on-device AI couldn't answer: "
                     + asked.prefix(4).map { "\"\($0.label.prefix(50))\"" }.joined(separator: ", "))
            let still = await ask(helper, asked, batchSize: 8, source: "cloud", profileText: cloudProfileText, job: job, feedback: feedback, into: &res)
            let answered = asked.count - still.count
            if answered > 0 {
                Log.info("The cloud AI answered \(answered) of \(asked.count); the on-device AI sees its confident answers from now on")
                memory.reload(db: db)
            }
            missed = still + missed.dropFirst(asked.count)
            if helperBudget <= 0 { Log.info("The cloud AI won't be asked again this run (its limit is reached)") }
        }
        // "If yes, please describe below" after a question answered No (CMG's, a required box): nothing to describe.
        missed = missed.filter { f in
            guard let na = Self.notApplicableFollowUp(f, in: fields, res) else { return true }
            res.answers[f.id] = na
            res.sources[f.id] = "rule"
            return false
        }
        for f in missed {
            park(f)
            if !f.required { res.unanswered.append(f) }
        }
        return Self.finish(res, fields)
    }

    /// A question about who the person is, which only they answer: their gender, pronouns, sexual orientation, race or
    /// ethnicity, veteran or disability status, and what equality monitoring asks besides (Pinpoint's "Religion",
    /// "Marital Status" and "Age Bracket", which the cloud AI was asked).
    public static func selfIdentification(_ f: FieldSpec) -> Bool {
        if let topic = QuestionTopic(question: f.label),
           [.pronouns, .transgender, .sexualOrientation, .gender, .hispanic, .race, .veteran, .disability].contains(topic) { return true }
        // Its choices say so when its label doesn't (Infosys's "Form CC-305 Page 1 of 1", the disability form's number).
        if ProfileRules.selfIdentificationTopic(f) != nil || Regex(#"\bcc-?305\b"#).matches(norm(f.label)) { return true }
        // (Not an equal-opportunity statement that lists religion and marital status among much else: TCS's, to acknowledge.)
        let n = norm(f.label)
        return n.count <= 120 && equalityMonitoring.matches(n) && !Regex(#"regard to|equal (employment )?opportunit|discriminat|protected (by|under|class)"#).matches(n)
    }

    static let equalityMonitoring = Regex(#"\breligio|\b(religion or )?belief\b|\bfaith\b|marital|civil partnership|relationship status|"#
        + #"\bage (bracket|range|group|band)\b|^age$|^what is your age|caring responsibilit|\bcarer\b|socio-?economic|social (class|background)|"#
        + #"first (in (your|my) (immediate )?family|generation) to (attend|go)|type of school|free school meals|parents?'? (occupation|education)"#)

    static let ifYesLabel = Regex(#"^(if (yes|so)|if you (answered|selected|said|checked|chose) "?yes"?)\b"#)

    /// "N/A" for a box that asks for details only if the question before it was answered Yes, when it was answered No.
    static func notApplicableFollowUp(_ f: FieldSpec, in fields: [FieldSpec], _ res: Resolution) -> String? {
        guard f.type == .text || f.type == .textarea, ifYesLabel.matches(norm(f.label)),
              let i = fields.firstIndex(where: { $0.id == f.id }), i > 0 else { return nil }
        let before = fields[i - 1]
        let answer = res.answers[before.id] ?? before.currentValue
        return Regex(#"^no\b"#).matches(norm(answer)) ? "N/A" : nil
    }

    /// Asks one AI about `fields` in batches and keeps the answers that are plausible, cite the profile, the job or what
    /// the user taught it, and are confident; caches them (source "llm:…" or "cloud:…"). Returns the fields it couldn't
    /// answer.
    private func ask(_ model: FormAnswering, _ fields: [FieldSpec], batchSize: Int, source: String, profileText: String, job: JobContext,
                     feedback: [String: String], into res: inout Resolution) async -> [FieldSpec] {
        var missed: [FieldSpec] = []
        for start in stride(from: 0, to: fields.count, by: batchSize) {
            let batch = Array(fields[start..<min(start + batchSize, fields.count)])
            let memories = memory.relevant(for: batch, limit: 6)
            var byID: [String: FieldAnswer] = [:]
            do {
                byID = try await model.answerFields(batch, profileText: profileText, job: job,
                                                    feedback: feedback.filter { k, _ in batch.contains { $0.id == k } }, memories: memories)
            } catch is CancellationError {
                missed += batch
                continue
            } catch AIError.unavailable(let why) where source == "cloud" {
                Log.warn("The cloud AI isn't available, so it won't be asked again this run: \(why)")
                helperDown = true
                return missed + fields[start...]
            } catch {
                Log.warn("\(source == "cloud" ? "The cloud AI" : "AI") failed on \(batch.count) field(s): \(error.localizedDescription)")
            }
            let corpus = profileTokens.union(contentTokens(job.description)).union(contentTokens(job.title))
                .union(contentTokens(job.company)).union(contentTokens(memories.joined(separator: "\n")))
            for f in batch {
                // (A city for "County", Conduent's: a box the AI misread, as the site's own autofill does.)
                guard var a = byID[f.id], let value = coerceAnswer(f, a.answer), plausible(f, value), !misplaced(f, value) else {
                    missed.append(f)
                    continue
                }
                if a.confidence != .low && !Self.isGrounded(f, value, a.evidence, corpus) {
                    Log.info("Ungrounded answer for \"\(f.label)\" treated as low confidence")
                    a.confidence = .low
                }
                if a.confidence == .low {
                    missed.append(f)
                    continue
                }
                let tag = "\(source):\(a.confidence.rawValue)"
                res.answers[f.id] = value
                res.sources[f.id] = tag
                if cacheable(f, job) {
                    db.cachePut(Self.hash(f), question: f.contextLabel, fieldType: f.type.rawValue, options: f.options, answer: value, source: tag)
                }
            }
        }
        return missed
    }

    /// The AI must cite words that really occur in the profile, the job or what the user taught it; a number must
    /// come from that citation.
    static func isGrounded(_ f: FieldSpec, _ answer: String, _ evidence: String, _ corpus: Set<String>) -> Bool {
        let ev = contentTokens(evidence)
        guard !ev.isEmpty, Double(ev.intersection(corpus).count) / Double(ev.count) >= 0.6 else { return false }
        if f.type == .number {
            let pattern = Regex(#"(?<![\d.])"# + NSRegularExpression.escapedPattern(for: answer) + #"(?![\d])"#, [])
            if !pattern.matches(evidence) { return false }
        }
        return true
    }

    public func flagUnresolved(_ res: Resolution, jobID: String, company: String) {
        for f in res.unresolved {
            db.addPending(Self.hash(f), question: f.contextLabel, fieldType: f.type.rawValue,
                          options: f.options.filter { !isPlaceholderOption($0) }, jobID: jobID, company: company)
        }
    }
}

/// The profile as compact text for the AI (short enough for the on-device model's context window).
public enum ProfileText {
    public static func render(_ p: Profile, bulletLimit: Int = 2) -> String {
        var lines: [String] = []
        func add(_ key: String, _ value: String) { if !value.trimmed.isEmpty { lines.append("\(key): \(value.trimmed)") } }
        let pe = p.personal
        add("name", pe.fullName)
        add("preferred_name", pe.preferredName)
        add("email", pe.email)
        add("phone", "\(pe.phoneCountryCode) \(pe.phone)")
        add("location", [pe.address.city, pe.address.state, pe.address.country].filter { !$0.trimmed.isEmpty }.joined(separator: ", "))
        add("linkedin", pe.linkedin)
        add("github", pe.github)
        add("portfolio", pe.portfolio)
        let wa = p.workAuthorization
        lines.append("work_authorization: authorized_to_work: \(wa.authorizedToWork); requires_sponsorship: \(wa.requiresSponsorship)"
            + (wa.visaStatus.isEmpty ? "" : "; visa_status: \(wa.visaStatus)") + (wa.citizenship.isEmpty ? "" : "; citizenship: \(wa.citizenship)")
            + "; security_clearance: \(wa.securityClearance.isEmpty ? "None" : wa.securityClearance)")
        let c = p.compensation
        if let base = c.desiredBase {
            lines.append("desired_salary: \(base) \(c.currency)" + (c.rangeMin.map { "; minimum: \($0)" } ?? "") + (c.rangeMax.map { "; maximum: \($0)" } ?? ""))
        }
        let pr = p.preferences
        lines.append("preferences: willing_to_relocate: \(pr.willingToRelocate); notice_period: \(pr.noticePeriod); earliest_start: \(pr.earliestStartDate); over_18: \(pr.over18)")
        add("summary", p.summary)
        add("skills", p.skills.joined(separator: ", "))
        if let total = p.totalYears { lines.append("total_years_experience: \(fmt(total))") }
        let years = p.skillYears
        if !years.isEmpty { lines.append("experience_years: " + years.map { "\($0.skill): \(fmt($0.years))" }.joined(separator: "; ")) }
        if !p.workHistory.isEmpty {
            lines.append("work_history:")
            for r in p.workHistory {
                lines.append("- \(r.title) at \(r.company) (\(r.startDate)–\(r.endDate.isEmpty ? "Present" : r.endDate))" + (r.location.isEmpty ? "" : ", \(r.location)"))
                for b in r.bullets.prefix(bulletLimit) { lines.append("  • \(b.prefix(160))") }
            }
        }
        if !p.education.isEmpty {
            lines.append("education:")
            for e in p.education {
                lines.append("- \([e.degree, e.fieldOfStudy].filter { !$0.isEmpty }.joined(separator: " in ")), \(e.school)" + (e.graduationDate.isEmpty ? "" : " (\(e.graduationDate))"))
            }
        }
        add("certifications", p.certifications.joined(separator: ", "))
        add("languages", p.languages.joined(separator: ", "))
        return lines.joined(separator: "\n")
    }

    static func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
}

/// Whether an answer could be right for the field at all, whatever its source: a ZIP code has digits and no currency,
/// an email has an @, a year is a year. (The AI once put a salary, "80000 USD", into "Postal Code".)
func plausible(_ f: FieldSpec, _ answer: String) -> Bool {
    let label = norm(f.label)
    let a = answer.trimmed
    guard !a.isEmpty, !f.hasOptions, f.type != .checkbox else { return true }
    if Regex(#"\b(zip|postal)\b|postcode"#).matches(label) {
        // Postal codes have digits and at most two letters in a row (SW1A 1AA, K1A 0B1); "80000 USD" is a salary.
        return Regex(#"^[A-Za-z0-9][A-Za-z0-9 -]{1,9}$"#, []).fullMatch(a) && a.contains(where: \.isNumber) && !Regex(#"[A-Za-z]{3,}"#, []).matches(a)
    }
    if f.type == .email || Regex(#"^(e-?mail|email address)$"#).matches(label) { return a.contains("@") && !a.contains(" ") }
    if f.type == .tel || Regex(#"\b(phone|mobile|cell)( number)?$"#).matches(label) {
        return a.filter(\.isNumber).count >= 7 && !Regex(#"[a-z]{3,}"#).matches(a.lowercased())
    }
    if Regex(#"\byear$|^year\b|\(yyyy\)"#).matches(label) { return Regex(#"^(19|20)\d\d$"#, []).fullMatch(a) }
    if Regex(#"\bmonth$"#).matches(label) {
        return Regex(#"^(0?[1-9]|1[0-2]|jan(uary)?|feb(ruary)?|mar(ch)?|apr(il)?|may|june?|july?|aug(ust)?|sep(t|tember)?|oct(ober)?|nov(ember)?|dec(ember)?)$"#)
            .fullMatch(a.lowercased())
    }
    if f.placeholder == "YYYY-MM" { return Regex(#"^(19|20)\d\d-(0[1-9]|1[0-2])$"#, []).fullMatch(a) }
    if Regex(#"^(first|last|middle|given|family) name$|^(full |legal )?name$"#).matches(label) { return !a.contains(where: \.isNumber) }
    if Regex(#"^city$|\bcity$"#).matches(label) { return !a.contains(where: \.isNumber) }
    if f.type == .url || Regex(#"^(your )?(linkedin|github|portfolio|website|personal website|personal site)( profile)?( url| link| address)?$|\burl\b"#).matches(label) {
        return a.contains(".") && !a.contains(" ")
    }
    return true
}
