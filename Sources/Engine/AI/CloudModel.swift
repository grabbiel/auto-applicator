import Foundation

/// The stronger AI in the cloud: a model on Amazon Bedrock behind a function in the owner's AWS account
/// (infra/cloud-browser.yaml). Only a signed-in cloud-browser user's credentials may call that function, and the
/// function may call only that one model. The app asks it only about form questions the on-device AI couldn't answer;
/// the answers it gives are saved, so the same question never needs it again, and are shown to the on-device AI as
/// past answers from then on.
public struct CloudModel: LanguageModel {
    public let region: String
    public let function: String
    public let displayName: String
    let credentials: @Sendable () async throws -> AWSCredentials
    let session: URLSession

    /// Nil when this copy of the app was built before the cloud AI was set up.
    public init?(config: CloudConfig, session: URLSession = .shared, credentials: @escaping @Sendable () async throws -> AWSCredentials) {
        guard let function = config.helperFunction, !function.isEmpty else { return nil }
        region = config.region
        self.function = function
        displayName = config.helperName
        self.credentials = credentials
        self.session = session
    }

    public var promptBudget: Int { 40000 }

    var invokeURL: URL { URL(string: "https://lambda.\(region).amazonaws.com/2015-03-31/functions/\(function)/invocations")! }

    public func generate(instructions: String, prompt: String, schema: AISchema) async throws -> [String: Any] {
        var request = URLRequest(url: invokeURL, timeoutInterval: 100)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["system": instructions, "prompt": prompt, "schema": schema.jsonSchema()])
        let creds: AWSCredentials
        do {
            creds = try await credentials()
        } catch {
            throw AIError.unavailable("The cloud AI needs the cloud browser sign-in. \(error.localizedDescription)")
        }
        SigV4(credentials: creds, region: region, service: "lambda").sign(&request)
        let (data, response) = try await session.data(for: request)
        return try Self.read(data, response as? HTTPURLResponse)
    }

    public func generateText(instructions: String, prompt: String) async throws -> String {
        throw AIError.unavailable("The cloud AI only answers form questions.")
    }

    /// The function's reply, {"answer": {…}} or {"error": "…"}. Lambda's own refusals come with other statuses.
    /// `unavailable` means it won't work for the rest of the run (no permission, or the model isn't enabled).
    static func read(_ data: Data, _ response: HTTPURLResponse?) throws -> [String: Any] {
        let status = response?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else {
            let message = (json?["message"] ?? json?["Message"]) as? String ?? ""
            switch status {
            case 401, 403:
                throw AIError.unavailable("This cloud sign-in may not use the cloud AI. Run scripts/deploy_cloud.sh again, rebuild the app, and sign in again. \(message)")
            case 404:
                throw AIError.unavailable("The cloud AI isn't set up in your AWS account. Run scripts/deploy_cloud.sh, then rebuild the app.")
            case 429:
                throw AIError.server("The cloud AI is busy.")
            default:
                throw AIError.server("The cloud AI failed (HTTP \(status)). \(message)")
            }
        }
        if response?.value(forHTTPHeaderField: "X-Amz-Function-Error") != nil {
            throw AIError.server("The cloud AI failed: \(json?["errorMessage"] as? String ?? "unknown error").")
        }
        if let error = json?["error"] as? String {
            switch error {
            case "too long": throw AIError.contextTooLong
            case "busy": throw AIError.server("The cloud AI is busy.")
            case "AccessDeniedException", "ResourceNotFoundException":
                // The model isn't enabled in the account (or needs a one-time form in the Bedrock console).
                throw AIError.unavailable("The cloud AI's model isn't available in your AWS account (\(error)). Check it in the Bedrock console, or deploy another one with AA_HELPER_MODEL.")
            default: throw AIError.server("The cloud AI couldn't answer (\(error)).")
            }
        }
        guard let answer = json?["answer"] as? [String: Any] else {
            throw AIError.badOutput(String(decoding: data.prefix(120), as: UTF8.self))
        }
        return answer
    }
}
