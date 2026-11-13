import Foundation
import NaturalLanguage

/// What the app has learned about the user beyond the profile: their answers to past questions and the facts they
/// taught it. It grows with every answer, and makes later applications need fewer questions:
/// - a question worded almost like one the user already answered reuses that answer;
/// - the most relevant facts and answers are given to the AI as extra evidence it may cite.
public final class Memory: @unchecked Sendable {
    struct Entry {
        let text: String
        let question: String?
        let answer: String?
        let fieldType: String?
        let tokens: Set<String>
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var vectors: [Int: [Double]] = [:]
    private let embedding: NLEmbedding?

    public init(db: Database) {
        embedding = NLEmbedding.sentenceEmbedding(for: .english)
        reload(db: db)
    }

    public func reload(db: Database) {
        var list: [Entry] = []
        for fact in db.facts() {
            list.append(Entry(text: "Fact: \(fact.text)", question: nil, answer: nil, fieldType: nil, tokens: contentTokens(fact.text)))
        }
        for a in db.cacheEntries() where a.learnedFromUser || a.source == "llm:high" {
            list.append(Entry(text: "Q: \(a.question) A: \(a.answer)", question: a.question, answer: a.learnedFromUser ? a.answer : nil,
                              fieldType: a.fieldType, tokens: contentTokens(a.question)))
        }
        lock.lock()
        entries = list
        vectors = [:]
        lock.unlock()
    }

    /// The user's own answer to an almost identically worded question, fitted to this field's options.
    public func similarAnswer(for f: FieldSpec) -> String? {
        let label = norm(f.label)
        guard label.count >= 8 else { return nil }
        lock.lock()
        let candidates = entries.filter { $0.answer != nil }
        lock.unlock()
        var best: (Double, String)?
        for e in candidates {
            guard let q = e.question, let answer = e.answer else { continue }
            let r = Difflib.ratio(norm(q), label)
            guard r >= 0.88 else { continue }
            if let value = coerceAnswer(f, answer), best == nil || r > best!.0 { best = (r, value) }
        }
        return best?.1
    }

    /// Up to `limit` facts and past answers most related to these fields, as lines for the AI's prompt.
    public func relevant(for fields: [FieldSpec], limit: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard !entries.isEmpty else { return [] }
        let labels = fields.map(\.label)
        let fieldTokens = labels.map(contentTokens)
        let fieldVectors = labels.map { vector(for: $0) }
        var scored: [(Double, Int)] = []
        for (i, e) in entries.enumerated() {
            var best = 0.0
            for (n, tokens) in fieldTokens.enumerated() {
                let union = tokens.union(e.tokens).count
                let jaccard = union == 0 ? 0 : Double(tokens.intersection(e.tokens).count) / Double(union)
                var sim = jaccard
                if let fv = fieldVectors[n], let ev = cachedVector(i, e) { sim = 0.6 * jaccard + 0.4 * max(0, cosine(fv, ev)) }
                best = max(best, sim)
            }
            if best > 0.12 { scored.append((best, i)) }
        }
        return scored.sorted { $0.0 > $1.0 }.prefix(limit).map { String(entries[$0.1].text.prefix(300)) }
    }

    private func cachedVector(_ i: Int, _ e: Entry) -> [Double]? {
        if let v = vectors[i] { return v }
        let v = vector(for: e.question ?? e.text)
        vectors[i] = v
        return v
    }

    private func vector(for text: String) -> [Double]? { embedding?.vector(for: text) }

    private func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for k in 0..<a.count { dot += a[k] * b[k]; na += a[k] * a[k]; nb += b[k] * b[k] }
        return na == 0 || nb == 0 ? 0 : dot / (na.squareRoot() * nb.squareRoot())
    }

    /// When the user answers "How many years of Rust?" with a number, the profile learns "Rust: n".
    public static func learnedSkill(question: String, answer: String) -> (skill: String, years: Double)? {
        guard let skill = skillInYearsQuestion(question) else { return nil }
        guard let n = Regex(#"\d+(?:\.\d+)?"#, []).allMatches(answer).first.flatMap(Double.init), n >= 0, n <= 60 else { return nil }
        return (skill, n)
    }
}

/// How much the app knows compared with what applications usually ask, with the most useful things to add next.
public struct KnowledgeReport: Sendable {
    public struct Item: Identifiable, Sendable {
        public enum Destination: String, Sendable { case profile, experience, workPay, jobs, memory, inbox, connections }
        public var id: String
        public var title: String
        public var detail: String
        public var done: Bool
        public var weight: Double
        public var destination: Destination
    }

    public var items: [Item]
    public var learnedAnswers: Int
    public var facts: Int

    public var score: Double {
        let total = items.reduce(0) { $0 + $1.weight }
        return total == 0 ? 0 : items.filter(\.done).reduce(0) { $0 + $1.weight } / total
    }

    public var suggestions: [Item] { items.filter { !$0.done }.sorted { $0.weight > $1.weight } }

    public init(profile: Profile, resumePresent: Bool, emailConfigured: Bool, learnedAnswers: Int, facts: Int, pending: Int) {
        self.learnedAnswers = learnedAnswers
        self.facts = facts
        let p = profile
        func item(_ id: String, _ title: String, _ detail: String, _ done: Bool, _ weight: Double, _ to: Item.Destination) -> Item {
            Item(id: id, title: title, detail: detail, done: done, weight: weight, destination: to)
        }
        items = [
            item("resume", "Add your resume", "Every application attaches it.", resumePresent, 3, .profile),
            item("contact", "Name, email and phone", "Asked on every form.", p.isComplete, 3, .profile),
            item("city", "Your city", "Most forms ask where you live.", !p.personal.address.city.trimmed.isEmpty, 1.5, .profile),
            item("linkedin", "Your LinkedIn profile link", "Many company sites ask for it.", !p.personal.linkedin.trimmed.isEmpty, 1, .profile),
            item("salary", "The salary you'd like", "A common required question.", p.compensation.desiredBase != nil, 2, .workPay),
            item("visa", "Citizenship or visa status", "Helps answer eligibility questions.", !p.workAuthorization.visaStatus.trimmed.isEmpty, 1, .workPay),
            item("total", "Total years of experience", "“How many years of experience?”", p.totalYears != nil, 2, .experience),
            item("skills", "Years for at least 5 skills", "“How many years of Excel?” is answered from these.", p.skillYears.count >= 5, 2.5, .experience),
            item("jobs", "Jobs you've had", "Used for “current employer” and cover letters.", !p.workHistory.isEmpty, 2, .experience),
            item("school", "Your education", "Schools, degrees and fields of study.", !p.education.isEmpty, 1.5, .experience),
            item("email", "Email codes", "Lets it finish sites that email you a code.", emailConfigured, 1.5, .connections),
            item("answers", "Answer 10 questions", "Each answer is reused on every future application.", learnedAnswers >= 10, 2, pending > 0 ? .inbox : .memory),
            item("facts", "Teach it 3 facts about you", "E.g. “I have a valid driver's license”.", facts >= 3, 1.5, .memory),
        ]
    }
}
