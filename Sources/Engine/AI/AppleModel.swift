import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether Apple's on-device model can be used on this Mac, and if not, why (in words for the user).
public enum AppleIntelligence {
    public enum Status: Equatable, Sendable {
        case available
        case notEnabled      // Apple Intelligence is off in System Settings
        case notReady        // still downloading its model
        case unsupported     // older macOS or Mac
    }

    public static var status: Status {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled: return .notEnabled
                case .modelNotReady: return .notReady
                default: return .unsupported
                }
            }
        }
        #endif
        return .unsupported
    }

    public static func makeModel() -> LanguageModel? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), status == .available { return AppleModel() }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
final class AppleModel: LanguageModel, @unchecked Sendable {
    let displayName = "Apple Intelligence"
    let promptBudget: Int

    init() {
        // ~3.5 characters per token; leave room for the instructions, the schema and the answer.
        promptBudget = max(6000, Self.contextTokens * 2)
    }

    // Swift 6.4 comes with the Xcode 27 SDK. Older SDKs (the release runners have Xcode 26) lack contextSize and spell
    // samplingMode as "sampling"; their model's window is 4096 tokens.
    #if compiler(>=6.4)
    private static var contextTokens: Int { SystemLanguageModel.default.contextSize }
    private var options: GenerationOptions { GenerationOptions(samplingMode: .greedy) }
    #else
    private static var contextTokens: Int { 4096 }
    private var options: GenerationOptions { GenerationOptions(sampling: .greedy) }
    #endif

    func prewarm() {
        LanguageModelSession().prewarm()
    }

    func generate(instructions: String, prompt: String, schema: AISchema) async throws -> [String: Any] {
        let session = LanguageModelSession(instructions: instructions)
        var counter = 0
        let root = Self.dynamic(schema, name: "Answer", counter: &counter)
        let generation = try GenerationSchema(root: root, dependencies: [])
        do {
            let response = try await session.respond(to: prompt, schema: generation, options: options)
            return try parseJSONObject(response.content.jsonString)
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.map(error)
        }
    }

    func generateText(instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        do {
            return try await session.respond(to: prompt, options: options).content
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.map(error)
        }
    }

    static func map(_ error: LanguageModelSession.GenerationError) -> AIError {
        switch error {
        case .exceededContextWindowSize: return .contextTooLong
        case .guardrailViolation, .refusal: return .refused
        case .assetsUnavailable: return .unavailable("Apple Intelligence isn't ready on this Mac yet.")
        default: return .server(error.localizedDescription)
        }
    }

    static func dynamic(_ schema: AISchema, name: String, counter: inout Int) -> DynamicGenerationSchema {
        counter += 1
        let unique = "\(name)\(counter)"
        switch schema {
        case .string: return DynamicGenerationSchema(type: String.self)
        case .number: return DynamicGenerationSchema(type: Double.self)
        case .bool: return DynamicGenerationSchema(type: Bool.self)
        case .choice(let values): return DynamicGenerationSchema(name: unique, anyOf: values)
        case .array(let item, let max):
            return DynamicGenerationSchema(arrayOf: dynamic(item, name: name + "Item", counter: &counter), minimumElements: 0, maximumElements: max)
        case .object(let props):
            let properties = props.map { key, value in
                DynamicGenerationSchema.Property(name: key, schema: dynamic(value, name: key.capitalized, counter: &counter))
            }
            return DynamicGenerationSchema(name: unique, properties: properties)
        }
    }
}
#endif
