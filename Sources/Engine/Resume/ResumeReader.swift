import Foundation
import PDFKit

/// What a resume says, ready to pre-fill the profile (the user reviews it in onboarding).
public struct ResumeFacts: Sendable, Equatable {
    public var firstName = "", lastName = "", email = "", phone = ""
    public var city = "", state = "", country = ""
    public var linkedin = "", github = "", portfolio = ""
    public var summary = ""
    public var skills: [String] = []
    public var experienceYears: [String: Double] = [:]
    public var totalYears: Double?
    public var workHistory: [Role] = []
    public var education: [Education] = []
    public var certifications: [String] = []

    public init() {}

    /// Fills only what the profile doesn't have yet (never overwrites what the user typed).
    public func merge(into p: inout Profile) {
        func fill(_ field: inout String, _ value: String) { if field.trimmed.isEmpty && !value.trimmed.isEmpty { field = value.trimmed } }
        fill(&p.personal.firstName, firstName)
        fill(&p.personal.lastName, lastName)
        fill(&p.personal.email, email)
        fill(&p.personal.phone, phone)
        fill(&p.personal.address.city, city)
        fill(&p.personal.address.state, state)
        if !country.isEmpty && (p.personal.address.country.isEmpty || p.personal.address.country == "United States") && p.personal.address.city.isEmpty {
            p.personal.address.country = country
        }
        fill(&p.personal.linkedin, linkedin)
        fill(&p.personal.github, github)
        fill(&p.personal.portfolio, portfolio)
        fill(&p.summary, summary)
        let known = Set(p.skills.map { $0.lowercased() })
        p.skills += skills.filter { !known.contains($0.lowercased()) }
        for (skill, years) in experienceYears where !p.experienceYears.keys.contains(where: { $0.lowercased() == skill.lowercased() }) {
            p.experienceYears[skill] = years
        }
        if let totalYears, p.experienceYears["total"] == nil { p.experienceYears["total"] = totalYears }
        if p.workHistory.isEmpty { p.workHistory = workHistory }
        if p.education.isEmpty { p.education = education }
        let certs = Set(p.certifications.map { $0.lowercased() })
        p.certifications += certifications.filter { !certs.contains($0.lowercased()) }
    }
}

public enum ResumeReader {
    public static func text(from url: URL) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        let text = doc.string ?? ""
        return text.trimmed.isEmpty ? nil : text
    }

    /// Reads a resume: the reliable parts (email, phone, links) by pattern, the rest with the AI, one section at a time
    /// so each piece fits the on-device model.
    public static func read(_ url: URL, ai: AIService?, progress: (@Sendable (String) -> Void)? = nil) async -> ResumeFacts? {
        guard let text = text(from: url) else { return nil }
        var facts = basics(text)
        let parts = sections(text)
        if let ai {
            await withAI(ai, text: text, parts: parts, facts: &facts, progress: progress)
        } else if let skills = parts["skills"] {
            facts.skills = splitList(skills)
        }
        if facts.totalYears == nil { facts.totalYears = yearsSpanned(facts.workHistory) }
        return facts
    }

    // MARK: patterns

    static func basics(_ text: String) -> ResumeFacts {
        var f = ResumeFacts()
        f.email = Regex(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, []).allMatches(text).first ?? ""
        if let phone = Regex(#"(?:\+?\d{1,3}[\s.-]?)?\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}"#, []).allMatches(text).first { f.phone = phone.trimmed }
        if let li = Regex(#"(?:https?://)?(?:[a-z]{2,3}\.)?linkedin\.com/in/[A-Za-z0-9_%-]+/?"#).allMatches(text).first { f.linkedin = withScheme(li) }
        if let gh = Regex(#"(?:https?://)?github\.com/[A-Za-z0-9_-]+/?"#).allMatches(text).first { f.github = withScheme(gh) }
        let others = Regex(#"(?:https?://)?(?:www\.)?[a-z0-9-]+\.(?:com|io|dev|me|net|org|co|app|site|xyz)(?:/[^\s,;|)]*)?"#).allMatches(text)
            .filter { !$0.contains("@") && !$0.contains("linkedin.") && !$0.contains("github.") && !$0.lowercased().contains(f.email.lowercased().split(separator: "@").last.map(String.init) ?? "@@") }
        if let site = others.first { f.portfolio = withScheme(site) }
        // The name is usually the first line with two to four capitalized words.
        for line in text.components(separatedBy: .newlines).prefix(6) {
            let words = line.trimmed.split(separator: " ").map(String.init)
            if (2...4).contains(words.count), words.allSatisfy({ $0.first?.isUppercase == true && $0.allSatisfy { $0.isLetter || "-.'".contains($0) } }) {
                f.firstName = words[0].capitalizedIfShouting
                f.lastName = words.dropFirst().map(\.capitalizedIfShouting).joined(separator: " ")
                break
            }
        }
        return f
    }

    static func withScheme(_ url: String) -> String {
        let u = url.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/.,"))
        return u.hasPrefix("http") ? u : "https://" + u
    }

    static let headings: [(String, Regex)] = [
        ("summary", Regex(#"^(professional )?(summary|profile|about( me)?|objective|career summary)$"#)),
        ("experience", Regex(#"^((professional|work|relevant|employment) )?(experience|history)$|^employment$|^career history$|^work$"#)),
        ("education", Regex(#"^education( (and|&) training)?$|^academic background$"#)),
        ("skills", Regex(#"^((technical|core|key) )?(skills|competencies|technologies|tools)( (and|&) (tools|technologies|interests))?$|^tech stack$"#)),
        ("certifications", Regex(#"^(certifications?|licenses?( (and|&) certifications)?|certificates)$"#)),
        ("projects", Regex(#"^(selected |personal )?projects$"#)),
        ("other", Regex(#"^(awards|honors|publications|volunteer(ing)?( experience)?|interests|languages|activities|references)$"#)),
    ]

    /// Splits the resume at its section headings ("Experience", "EDUCATION", …).
    static func sections(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        var current = "header"
        var buffer: [String] = []
        func flush() {
            let body = buffer.joined(separator: "\n").trimmed
            if !body.isEmpty { out[current] = [out[current], body].compactMap { $0 }.joined(separator: "\n") }
            buffer = []
        }
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":•|")).trimmed
            if t.count <= 40, let match = headings.first(where: { $0.1.fullMatch(t.lowercased()) }) {
                flush()
                current = match.0
                continue
            }
            buffer.append(line)
        }
        flush()
        return out
    }

    static func splitList(_ text: String) -> [String] {
        let items = text.components(separatedBy: CharacterSet(charactersIn: ",;•|\n·"))
            .map { $0.replacingOccurrences(of: #"^[A-Za-z &/]{2,30}:\s*"#, with: "", options: .regularExpression).trimmed }
            .filter { (1...40).contains($0.count) }
        var seen = Set<String>()
        return items.filter { seen.insert($0.lowercased()).inserted }.prefix(40).map { $0 }
    }

    /// Splits text into pieces of at most `size` characters at blank lines (or line breaks).
    static func chunks(_ text: String, size: Int) -> [String] {
        var out: [String] = []
        var current = ""
        for line in text.components(separatedBy: "\n") {
            if current.count + line.count + 1 > size, !current.isEmpty {
                out.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + String(line.prefix(size))
        }
        if !current.trimmed.isEmpty { out.append(current) }
        return out
    }

    // MARK: AI

    static let instructions = """
    You read resumes and copy their facts. Copy names, companies, titles, schools and dates exactly as written. \
    Use "" for anything the text doesn't contain. Dates as YYYY-MM when possible; "Present" for a current role.
    """

    static func withAI(_ ai: AIService, text: String, parts: [String: String], facts: inout ResumeFacts,
                       progress: (@Sendable (String) -> Void)?) async {
        let compact = ai.model.isCompact
        let chunkSize = compact ? 2600 : 7000
        func ask(_ prompt: String, _ schema: AISchema) async -> [String: Any]? {
            do { return try await ai.model.generate(instructions: instructions, prompt: prompt, schema: schema) } catch {
                Log.warn("Resume reading step failed: \(error.localizedDescription)")
                return nil
            }
        }
        let s = AIService.string

        progress?("Reading your contact details")
        let head = (parts["header"] ?? String(text.prefix(1200))).prefix(1500) + "\n" + (parts["summary"] ?? "").prefix(1500)
        if let j = await ask("Resume top:\n\(head)", .object([("first_name", .string), ("last_name", .string), ("city", .string),
                                                            ("state", .string), ("country", .string), ("summary", .string)])) {
            if !s(j["first_name"]).isEmpty { facts.firstName = s(j["first_name"]) }
            if !s(j["last_name"]).isEmpty { facts.lastName = s(j["last_name"]) }
            facts.city = s(j["city"]); facts.state = s(j["state"]); facts.country = s(j["country"])
            facts.summary = String(s(j["summary"]).prefix(800))
        }

        progress?("Reading your work history")
        let roleSchema = AISchema.object([("company", .string), ("title", .string), ("location", .string), ("start_date", .string),
                                          ("end_date", .string), ("bullets", .array(.string, max: compact ? 3 : 5))])
        let experience = parts["experience"] ?? (parts.count <= 2 ? text : "")
        for chunk in chunks(experience, size: chunkSize).prefix(6) {
            guard let j = await ask("Work experience section:\n\(chunk)", .object([("roles", .array(roleSchema, max: 6))])),
                  let roles = j["roles"] as? [[String: Any]] else { continue }
            for r in roles {
                let role = Role(company: s(r["company"]), title: s(r["title"]), location: s(r["location"]), startDate: s(r["start_date"]),
                                endDate: s(r["end_date"]).isEmpty ? "Present" : s(r["end_date"]),
                                bullets: ((r["bullets"] as? [Any]) ?? []).map(s).filter { !$0.isEmpty })
                guard !role.company.isEmpty || !role.title.isEmpty else { continue }
                // a role split across two chunks: keep the first, add the second's bullets
                if let i = facts.workHistory.firstIndex(where: { $0.company.lowercased() == role.company.lowercased() && $0.title.lowercased() == role.title.lowercased() }) {
                    facts.workHistory[i].bullets += role.bullets
                } else {
                    facts.workHistory.append(role)
                }
            }
        }

        if let edu = parts["education"] {
            progress?("Reading your education")
            let eduSchema = AISchema.object([("school", .string), ("degree", .string), ("field_of_study", .string), ("graduation_date", .string)])
            if let j = await ask("Education section:\n\(edu.prefix(chunkSize))", .object([("education", .array(eduSchema, max: 5))])),
               let list = j["education"] as? [[String: Any]] {
                facts.education = list.map { Education(school: s($0["school"]), degree: s($0["degree"]), fieldOfStudy: s($0["field_of_study"]),
                                                       graduationDate: s($0["graduation_date"])) }.filter { !$0.school.isEmpty }
            }
        }

        progress?("Reading your skills")
        let skillText = [parts["skills"], parts["certifications"]].compactMap { $0 }.joined(separator: "\n")
        if !skillText.isEmpty,
           let j = await ask("Skills and certifications:\n\(skillText.prefix(chunkSize))",
                             .object([("skills", .array(.string, max: 30)), ("certifications", .array(.string, max: 10))])) {
            facts.skills = ((j["skills"] as? [Any]) ?? []).map(s).map { $0.replacingOccurrences(of: #"\s*[(\[]\s*\d+(\.\d+)?\+?\s*(years?|yrs?)\s*[)\]]"#, with: "", options: [.regularExpression, .caseInsensitive]) }
                .filter { !$0.isEmpty }
            facts.certifications = ((j["certifications"] as? [Any]) ?? []).map(s).filter { !$0.isEmpty }
        } else if let skills = parts["skills"] {
            facts.skills = splitList(skills)
        }

        // Years per main skill, from the roles that use it.
        guard !facts.skills.isEmpty, !facts.workHistory.isEmpty else { return }
        progress?("Working out your years of experience")
        let roles = facts.workHistory.prefix(8).map { r in
            "- \(r.title) at \(r.company) (\(r.startDate)–\(r.endDate)): " + r.bullets.prefix(2).joined(separator: " ").prefix(compact ? 160 : 300)
        }.joined(separator: "\n")
        let prompt = "Today: \(AIService.today)\nSkills: \(facts.skills.prefix(20).joined(separator: ", "))\n\nRoles:\n\(roles)\n\n" +
            "For each of the main skills (at most 12), give the years of hands-on experience: as stated, or the length of the roles that use it."
        let item = AISchema.object([("skill", .string), ("years", .number)])
        if let j = await ask(prompt, .object([("experience_years", .array(item, max: 12))])), let list = j["experience_years"] as? [[String: Any]] {
            for e in list {
                let skill = s(e["skill"])
                if let years = (e["years"] as? NSNumber)?.doubleValue, !skill.isEmpty, years > 0, years <= 50 {
                    facts.experienceYears[skill] = (years * 2).rounded() / 2
                }
            }
        }
    }

    /// Years from the earliest start date to the latest end date (or today).
    static func yearsSpanned(_ roles: [Role]) -> Double? {
        func year(_ s: String) -> Double? {
            guard let g = Regex(#"((?:19|20)\d{2})(?:[-/.](\d{1,2}))?"#, []).firstGroups(s), let y = Double(g[1] ?? "") else { return nil }
            let m = Double(g[2] ?? "") ?? 6
            return y + (m - 1) / 12
        }
        let starts = roles.compactMap { year($0.startDate) }
        guard let first = starts.min() else { return nil }
        let now = Double(Calendar.current.component(.year, from: Date())) + Double(Calendar.current.component(.month, from: Date()) - 1) / 12
        let ends = roles.map { $0.isCurrent ? now : (year($0.endDate) ?? now) }
        let span = (ends.max() ?? now) - first
        return span > 0 ? (span * 2).rounded() / 2 : nil
    }
}

extension String {
    /// "SMITH" → "Smith"; "McDonald" stays.
    var capitalizedIfShouting: String { self == uppercased() && count > 1 ? capitalized : self }
}
