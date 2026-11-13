import Foundation

/// Everything the app asks of the on-device AI: form answers, cover letters, reading verification emails and
/// confirmation pages.
public final class AIService: FormAnswering, @unchecked Sendable {
    public let model: LanguageModel

    public init(model: LanguageModel) { self.model = model }

    public var displayName: String { model.displayName }

    /// Fields per AI call: the on-device Apple model has a small context window.
    public var batchSize: Int { model.isCompact ? 3 : 6 }

    /// Picks the engine from the settings: Apple Intelligence when available (or chosen), else Ollama.
    public static func make(settings: AISettings, ollama: OllamaManager) async throws -> AIService {
        switch settings.engine {
        case .apple:
            guard let m = AppleIntelligence.makeModel() else { throw AIError.unavailable(AppleIntelligence.status.explanation) }
            return AIService(model: m)
        case .ollama:
            return AIService(model: try await ollama.model(named: settings.ollamaModel))
        case .automatic:
            if let m = AppleIntelligence.makeModel() { return AIService(model: m) }
            if ollama.isInstalled, await ollama.hasModel(settings.ollamaModel) {
                return AIService(model: try await ollama.model(named: settings.ollamaModel))
            }
            throw AIError.unavailable(AppleIntelligence.status.explanation)
        }
    }

    // MARK: form fields

    static let formInstructions = """
    You fill in job application form fields for a candidate.
    Rules:
    1. Ground every answer in the CANDIDATE and JOB text. Never invent employers, degrees, dates, links, numbers or experience.
    2. Number fields and "how many years" questions: digits only, e.g. 3.
    3. Fields with options: the answer must be one of the options, copied exactly.
    4. A single checkbox: Yes to tick it, No to leave it. Tick truthful attestations ("I certify the information is accurate").
    5. Work authorization, sponsorship, relocation and start date come from the candidate's work_authorization and preferences lines.
    6. Free-text questions about motivation or fit: 2–4 sentences in the first person, specific to the job, using only the candidate's facts.
    7. evidence: copy the exact words from CANDIDATE or JOB the answer rests on, e.g. "requires_sponsorship: false". Empty if none.
    8. confidence: high = stated directly; medium = a safe inference; low = not in the text. Always low with empty evidence for things \
    the text doesn't state, however obvious a guess seems: criminal history, self-ratings, years with a skill not listed, references, \
    salary history, licenses, test scores.
    """

    public func answerFields(_ fields: [FieldSpec], profileText: String, job: JobContext, feedback: [String: String],
                             memories: [String]) async throws -> [String: FieldAnswer] {
        let compact = model.isCompact
        do {
            return try await answer(fields, profileText, job, feedback, memories,
                                    jobChars: compact ? 900 : 2500, profileChars: compact ? 4200 : 12000, memoryCount: compact ? 4 : 8)
        } catch AIError.contextTooLong {
            Log.info("Prompt too long for \(fields.count) field(s); retrying with less context")
        }
        do {
            return try await answer(fields, profileText, job, feedback, Array(memories.prefix(2)),
                                    jobChars: 300, profileChars: 2600, memoryCount: 2)
        } catch AIError.contextTooLong where fields.count > 1 {
            var all: [String: FieldAnswer] = [:]
            for f in fields {
                let one = try await answerFields([f], profileText: profileText, job: job, feedback: feedback.filter { $0.key == f.id }, memories: memories)
                all.merge(one) { a, _ in a }
            }
            return all
        }
    }

    private func answer(_ fields: [FieldSpec], _ profileText: String, _ job: JobContext, _ feedback: [String: String], _ memories: [String],
                        jobChars: Int, profileChars: Int, memoryCount: Int) async throws -> [String: FieldAnswer] {
        var props: [(String, AISchema)] = []
        var lines: [String] = []
        for (i, f) in fields.enumerated() {
            let key = "field\(i + 1)"
            let options = f.options.filter { !isPlaceholderOption($0) }
            var answerSchema = AISchema.string
            if f.type == .checkbox {
                answerSchema = .choice(["Yes", "No"])
            } else if [.select, .radio, .combobox].contains(f.type) && !options.isEmpty {
                answerSchema = .choice(options)
            }
            props.append((key, .object([("evidence", .string), ("answer", answerSchema), ("confidence", .choice(["high", "medium", "low"]))])))
            var line = "\(key): \"\(f.label.trimmed)\" (\(f.type.rawValue)\(f.required ? ", required" : ""))"
            if !options.isEmpty { line += " options: " + options.map { "\"\($0)\"" }.joined(separator: ", ") }
            if let max = f.maxLength { line += " max \(max) characters" }
            if !f.placeholder.isEmpty && f.placeholder != f.label { line += " placeholder: \"\(f.placeholder)\"" }
            if let error = feedback[f.id], !error.isEmpty { line += "\n  The form rejected the last answer: \"\(error)\" — fix it." }
            lines.append(line)
        }
        var prompt = "CANDIDATE:\n\(String(profileText.prefix(profileChars)))\n"
        let mem = memories.prefix(memoryCount)
        if !mem.isEmpty { prompt += "\nThings the candidate told us before:\n" + mem.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        prompt += "\nJOB:\n\(job.prompt(maxChars: jobChars))\n\nToday: \(Self.today)\n\nFIELDS:\n" + lines.joined(separator: "\n")

        let json = try await model.generate(instructions: Self.formInstructions, prompt: prompt, schema: .object(props))
        var out: [String: FieldAnswer] = [:]
        for (i, f) in fields.enumerated() {
            guard let a = json["field\(i + 1)"] as? [String: Any] else { continue }
            let answer = Self.string(a["answer"])
            let confidence = Confidence(rawValue: Self.string(a["confidence"]).lowercased()) ?? .low
            out[f.id] = FieldAnswer(evidence: Self.string(a["evidence"]), answer: answer, confidence: answer.isEmpty ? .low : confidence)
        }
        return out
    }

    static func string(_ v: Any?) -> String {
        switch v {
        case let s as String: return s.trimmed
        case let n as NSNumber: return n.stringValue
        case let a as [Any]: return a.map { string($0) }.joined(separator: " ; ")
        default: return ""
        }
    }

    static var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    // MARK: cover letters

    public func coverLetter(profile: Profile, job: JobContext) async throws -> String {
        let instructions = """
        Write a concise, specific cover letter: 150–220 words in 3 short paragraphs. Start with "Dear Hiring Team," and end \
        with "Sincerely," and the candidate's full name. No address block, date or placeholders. Use only the candidate's \
        work history, skills and education, connected to what the job asks for. Don't mention relocation, start dates, \
        salary, visas or spoken languages.
        """
        let compact = model.isCompact
        let profileText = ProfileText.render(profile, bulletLimit: compact ? 2 : 4)
        let prompt = "CANDIDATE:\n\(profileText.prefix(compact ? 3500 : 9000))\n\nJOB:\n\(job.prompt(maxChars: compact ? 1500 : 3500))"
        var letter = try await model.generateText(instructions: instructions, prompt: prompt).trimmed
        letter = letter.replacingOccurrences(of: #"(?m)^\s*\[[^\]]{2,40}\]\s*$\n?"#, with: "", options: .regularExpression)
        // drop anything before the greeting (models sometimes add an address line)
        if let greeting = letter.range(of: "Dear ", options: .caseInsensitive), letter.distance(from: letter.startIndex, to: greeting.lowerBound) < 200 {
            letter = String(letter[greeting.lowerBound...])
        }
        return letter.trimmed
    }

    // MARK: emails and pages

    func extractVerification(_ e: ParsedEmail) async throws -> (code: String?, url: String?) {
        let instructions = """
        Extract the verification code and the verification link from this email sent by a job site. The code is the short token \
        the user must type (often 6 digits or 8 letters and digits). The link verifies or confirms the email or account. \
        Use an empty string for anything missing.
        """
        let links = e.links.prefix(30).map { "\($0.0) <\($0.1)>" }.joined(separator: "\n")
        let body = "Subject: \(e.subject)\nFrom: \(e.sender)\n\n\(e.text.prefix(model.isCompact ? 2500 : 5000))\n\nLinks:\n\(links)"
        let json = try await model.generate(instructions: instructions, prompt: String(body.prefix(model.isCompact ? 6000 : 12000)),
                                            schema: .object([("code", .string), ("verification_url", .string)]))
        let code = Self.string(json["code"]), url = Self.string(json["verification_url"])
        return (code.isEmpty ? nil : code, url.hasPrefix("http") ? url : nil)
    }

    /// Reads the page shown after pressing Submit: did the application go through?
    public func checkSubmission(pageText: String) async throws -> (submitted: Bool, evidence: String) {
        let instructions = """
        Below is the visible text of a web page shown right after a job application form was submitted. Decide whether the \
        application was successfully submitted (a thank-you or confirmation message) or not (errors, the form is still shown, \
        an error page). evidence: the words that show it.
        """
        let json = try await model.generate(instructions: instructions, prompt: String(pageText.prefix(model.isCompact ? 3500 : 5000)),
                                            schema: .object([("evidence", .string), ("submitted", .bool)]))
        return ((json["submitted"] as? Bool) ?? false, Self.string(json["evidence"]))
    }
}

extension AppleIntelligence.Status {
    public var explanation: String {
        switch self {
        case .available: "Apple Intelligence is ready."
        case .notEnabled: "Turn on Apple Intelligence in System Settings › Apple Intelligence & Siri."
        case .notReady: "Apple Intelligence is still downloading. It usually finishes within an hour."
        case .unsupported: "Apple Intelligence needs macOS 26 on an Apple silicon Mac. You can use Ollama instead."
        }
    }
}
