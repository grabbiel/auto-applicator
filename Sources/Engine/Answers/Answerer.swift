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
}

public struct Resolution: Sendable {
    public var answers: [String: String] = [:]
    /// Required fields without a confident answer: the job is skipped and the question goes to the user.
    public var unresolved: [FieldSpec] = []
    /// Optional fields without a confident answer: left empty.
    public var leftBlank: [FieldSpec] = []
    /// Required fields the person said they can't answer: the job is skipped for good.
    public var declined: [FieldSpec] = []
    /// Where each answer came from: "cache", "profile", "memory", "llm:high" / "llm:medium" (the on-device AI) or
    /// "cloud:high" / "cloud:medium" (the cloud AI).
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
        return job.company.isEmpty || !norm(f.label).contains(norm(job.company))
    }

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

    /// The same answer written another way: "(512) 555-0142" and "5125550142", "OR - Oregon" and "Oregon".
    static func sameAnswer(_ mine: String, _ current: String) -> Bool {
        // A link is the same only in the same form: sites turn away "linkedin.com/in/…" without https://.
        if Regex(#"^(https?://|www\.)|\.(com|org|net|io|dev|me)(/|$)"#).matches(mine.trimmed) {
            return mine.trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) ==
                current.trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        let a = norm(mine).filter { $0.isLetter || $0.isNumber }, b = norm(current).filter { $0.isLetter || $0.isNumber }
        if a == b || (min(a.count, b.count) >= 4 && (a.contains(b) || b.contains(a))) { return true }
        let da = mine.filter(\.isNumber), db = current.filter(\.isNumber)
        if da.count >= 7, db.count >= 7, da.hasSuffix(db) || db.hasSuffix(da) { return true }
        return matchOption(mine, [current]) != nil
    }

    public func resolve(_ fields: [FieldSpec], job: JobContext, feedback: [String: String] = [:]) async -> Resolution {
        var res = Resolution()
        var todo: [FieldSpec] = []
        func park(_ f: FieldSpec) { if f.required { res.unresolved.append(f) } else { res.leftBlank.append(f) } }

        for f in fields where f.type != .file {
            let fb = feedback[f.id]
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
            if fb == nil && !f.currentValue.isEmpty && f.error.isEmpty { continue }  // already filled (e.g. by LinkedIn)
            // A box named only by its placeholder ("Select"): its question wasn't found, and any answer would be a guess
            // at a question nobody read (Rippling's lists all got "Yes", "please pick the opposite of Yes" too).
            if Self.placeholderLabel.matches(norm(f.label)) {
                park(f)
                continue
            }
            let qh = Self.hash(f)
            if db.cacheSource(qh) == "declined" {
                if f.required { res.declined.append(f) } else { res.leftBlank.append(f) }
                continue
            }
            // What the profile says beats an answer the AI saved before (TCS's skills as "Java (1); C# (1); …"); the
            // person's own answers still come first.
            let personal = ["user", "edited"].contains(db.cacheSource(qh) ?? "")
            // Also when the form says a box it was given is empty (it lost the answer when the page redrew, Serco's
            // "Mobile Phone"): the profile's answer again, not a question for the person.
            if fb == nil || f.currentValue.trimmed.isEmpty, !personal, let given = fromProfile(f, job: job) {
                if db.cacheSource(qh) != nil, db.cacheGet(qh) != given { db.cacheDelete(qh) }  // a guess the profile corrects
                res.answers[f.id] = given
                res.sources[f.id] = "profile"
                continue
            }
            if fb != nil && !f.currentValue.isEmpty {
                // The form rejected the value we entered: forget it and ask the AI with the error message.
                if let source = db.cacheSource(qh), source != "user", source != "edited" { db.cacheDelete(qh) }
                todo.append(f)
                continue
            }
            if let cached = coerceAnswer(f, db.cacheGet(qh)) {
                if plausible(f, cached) {
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
            if let remembered = memory.similarAnswer(for: f), plausible(f, remembered) {
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

        guard !todo.isEmpty else { return res }
        var missed = todo
        if let ai {
            missed = await ask(ai, todo, batchSize: batchSize, source: "llm", profileText: profileText, job: job, feedback: feedback, into: &res)
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
        missed.forEach(park)
        return res
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
                guard var a = byID[f.id], let value = coerceAnswer(f, a.answer), plausible(f, value) else {
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
