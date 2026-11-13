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
    /// Where each answer came from: "cache", "profile", "memory" or "llm:high" / "llm:medium".
    public var sources: [String: String] = [:]
    public var blocked: Bool { !unresolved.isEmpty }
}

/// Answers form fields: answers the user gave before → the profile → similar questions the user answered → the
/// on-device AI, which must cite the profile. An answer the AI isn't confident about is never submitted: if the field
/// is required, the application is skipped and the question is saved for the user to answer once.
public final class Answerer: @unchecked Sendable {
    public let profile: Profile
    public let db: Database
    let ai: FormAnswering?
    public let memory: Memory
    let batchSize: Int
    public let profileText: String
    private let profileTokens: Set<String>

    public init(profile: Profile, db: Database, ai: FormAnswering?, memory: Memory? = nil, batchSize: Int = 6) {
        self.profile = profile
        self.db = db
        self.ai = ai
        self.memory = memory ?? Memory(db: db)
        self.batchSize = max(1, batchSize)
        profileText = ProfileText.render(profile)
        profileTokens = contentTokens(profileText)
    }

    private func cacheable(_ f: FieldSpec, _ job: JobContext) -> Bool {
        if f.type == .textarea || f.type == .file { return false }
        return job.company.isEmpty || !norm(f.label).contains(norm(job.company))
    }

    public func resolve(_ fields: [FieldSpec], job: JobContext, feedback: [String: String] = [:]) async -> Resolution {
        var res = Resolution()
        var todo: [FieldSpec] = []
        func park(_ f: FieldSpec) { if f.required { res.unresolved.append(f) } else { res.leftBlank.append(f) } }

        for f in fields where f.type != .file {
            let fb = feedback[f.id]
            if fb == nil && !f.currentValue.isEmpty && f.error.isEmpty { continue }  // already filled (e.g. by LinkedIn)
            let qh = questionHash(f.label, f.type.rawValue, f.options)
            if fb != nil && !f.currentValue.isEmpty {
                // The form rejected the value we entered: forget it and ask the AI with the error message.
                if let source = db.cacheSource(qh), source != "user", source != "edited" { db.cacheDelete(qh) }
                todo.append(f)
                continue
            }
            if let cached = coerceAnswer(f, db.cacheGet(qh)) {
                res.answers[f.id] = cached
                res.sources[f.id] = "cache"
                continue
            }
            if let ruled = coerceAnswer(f, ProfileRules.answer(profile, f)) {
                res.answers[f.id] = ruled
                res.sources[f.id] = "profile"
                continue
            }
            if let remembered = memory.similarAnswer(for: f) {
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
        guard let ai else {
            todo.forEach(park)
            return res
        }
        var start = 0
        while start < todo.count {
            let batch = Array(todo[start..<min(start + batchSize, todo.count)])
            start += batchSize
            let memories = memory.relevant(for: batch, limit: 6)
            var byID: [String: FieldAnswer] = [:]
            do {
                byID = try await ai.answerFields(batch, profileText: profileText, job: job,
                                                 feedback: feedback.filter { k, _ in batch.contains { $0.id == k } }, memories: memories)
            } catch is CancellationError {
                batch.forEach(park)
                continue
            } catch {
                Log.warn("AI failed on \(batch.count) field(s): \(error.localizedDescription)")
            }
            let corpus = profileTokens.union(contentTokens(job.description)).union(contentTokens(job.title))
                .union(contentTokens(job.company)).union(contentTokens(memories.joined(separator: "\n")))
            for f in batch {
                guard var a = byID[f.id], let value = coerceAnswer(f, a.answer) else {
                    park(f)
                    continue
                }
                if a.confidence != .low && !Self.isGrounded(f, value, a.evidence, corpus) {
                    Log.info("Ungrounded answer for \"\(f.label)\" treated as low confidence")
                    a.confidence = .low
                }
                if a.confidence == .low {
                    park(f)
                    continue
                }
                res.answers[f.id] = value
                res.sources[f.id] = "llm:\(a.confidence.rawValue)"
                if cacheable(f, job) {
                    db.cachePut(questionHash(f.label, f.type.rawValue, f.options), question: f.label, fieldType: f.type.rawValue,
                                options: f.options, answer: value, source: "llm:\(a.confidence.rawValue)")
                }
            }
        }
        return res
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
            db.addPending(questionHash(f.label, f.type.rawValue, f.options), question: f.label, fieldType: f.type.rawValue,
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
