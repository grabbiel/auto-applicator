import Foundation

/// The shape of an answer the AI must produce. Both engines enforce it while generating (Apple's guided generation,
/// Ollama's JSON-schema grammar), so the output always parses and option answers are always one of the options.
public indirect enum AISchema: Sendable {
    case string
    case choice([String])
    case number
    case bool
    case array(AISchema, max: Int?)
    case object([(String, AISchema)])

    public func jsonSchema() -> [String: Any] {
        switch self {
        case .string: return ["type": "string"]
        case .choice(let values): return ["type": "string", "enum": values]
        case .number: return ["type": "number"]
        case .bool: return ["type": "boolean"]
        case .array(let item, let max):
            var s: [String: Any] = ["type": "array", "items": item.jsonSchema()]
            if let max { s["maxItems"] = max }
            return s
        case .object(let props):
            var properties: [String: Any] = [:]
            for (k, v) in props { properties[k] = v.jsonSchema() }
            return ["type": "object", "properties": properties, "required": props.map(\.0), "additionalProperties": false]
        }
    }

    /// Property names in order (JSON objects lose it; Ollama follows the "required" order).
    var orderedKeys: [String] { if case .object(let p) = self { return p.map(\.0) } else { return [] } }
}

public enum AIError: LocalizedError, Sendable {
    case unavailable(String)
    case contextTooLong
    case refused
    case badOutput(String)
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let m): m
        case .contextTooLong: "The text was too long for the on-device AI."
        case .refused: "The AI declined to answer this."
        case .badOutput(let m): "The AI's answer couldn't be read (\(m))."
        case .server(let m): m
        }
    }
}

/// An on-device language model.
public protocol LanguageModel: Sendable {
    var displayName: String { get }
    /// Roughly how many characters of prompt fit (the on-device Apple model has a small context window).
    var promptBudget: Int { get }
    func generate(instructions: String, prompt: String, schema: AISchema) async throws -> [String: Any]
    func generateText(instructions: String, prompt: String) async throws -> String
    func prewarm()
}

extension LanguageModel {
    public func prewarm() {}
    var isCompact: Bool { promptBudget < 9000 }
}

func parseJSONObject(_ text: String) throws -> [String: Any] {
    var t = text.trimmed
    if t.hasPrefix("```") {
        t = t.replacingOccurrences(of: #"^```(?:json)?\s*|\s*```$"#, with: "", options: .regularExpression)
    }
    guard let data = t.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw AIError.badOutput(String(t.prefix(120)))
    }
    return obj
}
