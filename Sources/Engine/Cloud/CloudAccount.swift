import CryptoKit
import Foundation

/// Where the optional cloud browser lives. scripts/deploy_cloud.sh writes it; the build copies it into the app.
public struct CloudConfig: Codable, Sendable, Equatable {
    public var region: String
    public var userPoolId: String
    public var clientId: String
    public var signInHost: String
    public var identityPoolId: String
    public var browserId: String
    public var browserProfileId: String
    /// Google and Apple, when the sign-in page offers them ("Google", "SignInWithApple"); missing in older files.
    public var signInProviders: [String]?

    /// The offered providers as people call them.
    public var providerNames: [String] {
        (signInProviders ?? []).map { $0 == "SignInWithApple" ? "Apple" : $0 }
    }

    public static let callbackScheme = "autoapplicator"
    public static let callback = "autoapplicator://auth"

    /// `cloud.json` in the data folder (if someone put one there), else the copy inside the app.
    public static func load(paths: AppPaths, bundle: Bundle = .main) -> CloudConfig? {
        let candidates = [paths.home.appendingPathComponent("cloud.json"), bundle.url(forResource: "CloudConfig", withExtension: "json")]
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url), let config = try? JSONDecoder().decode(CloudConfig.self, from: data) { return config }
        }
        return nil
    }

    var issuer: String { "cognito-idp.\(region).amazonaws.com/\(userPoolId)" }
}

public enum CloudError: LocalizedError, Equatable {
    case signedOut
    case failed(String)
    /// A first Google or Apple sign-in was just joined to its invitation; the same sign-in needs one more go.
    case joined(provider: String)

    public var errorDescription: String? {
        switch self {
        case .signedOut: "Sign in to the cloud browser again (Settings → Cloud browser)."
        case .failed(let m): m
        case .joined: "Your sign-in was joined to your invitation. Sign in once more."
        }
    }

    /// What the sign-in page reported, in words for the user.
    static func signIn(_ error: String, description: String?) -> CloudError {
        let text = (description ?? error).replacingOccurrences(of: "+", with: " ").trimmingCharacters(in: .whitespaces)
        // Cognito may refuse the first Google or Apple sign-in right after the invite gate joined it to the invited
        // account ("Already found an entry for username Google_1234"); the next attempt goes through.
        if let range = text.range(of: "Already found an entry for username ") {
            let provider = text[range.upperBound...].prefix { $0 != "_" }
            if !provider.isEmpty { return .joined(provider: String(provider)) }
        }
        // A refusal from the invite gate arrives as "PreSignUp failed with error <its message>."
        if let range = text.range(of: " failed with error ") {
            var message = String(text[range.upperBound...])
            while message.hasSuffix("..") { message.removeLast() }
            return .failed(message)
        }
        return .failed(text)
    }
}

/// The invited person using the cloud browser: signs in on the hosted page (password, passkey, Google or Apple), keeps
/// the sign-in (a refresh token, good for 30 days), and trades it for AWS credentials that can only use the browser.
public actor CloudAccount {
    public nonisolated let config: CloudConfig
    private var refreshToken: String?
    private var idToken: (token: String, expires: Date)?
    private var identityId: String?
    private var cached: AWSCredentials?
    /// Called whenever the stored sign-in changes (nil = signed out) so the app can save it.
    private let onChange: @Sendable (String?) -> Void

    public init(config: CloudConfig, refreshToken: String?, onChange: @escaping @Sendable (String?) -> Void) {
        self.config = config
        self.refreshToken = refreshToken?.isEmpty == true ? nil : refreshToken
        self.onChange = onChange
    }

    public var isSignedIn: Bool { refreshToken != nil }

    // MARK: sign-in (authorization code + PKCE)

    public struct SignInRequest: Sendable {
        public let url: URL
        let verifier: String
        let state: String
    }

    /// `identityProvider` ("Google", "SignInWithApple") skips the page and goes straight to that provider.
    public nonisolated func signInRequest(page: String = "oauth2/authorize", identityProvider: String? = nil) -> SignInRequest {
        let verifier = Self.randomURLSafe(32)
        let state = Self.randomURLSafe(16)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var c = URLComponents(string: "https://\(config.signInHost)/\(page)")!
        c.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: config.clientId),
            .init(name: "redirect_uri", value: CloudConfig.callback), .init(name: "scope", value: "openid email aws.cognito.signin.user.admin"),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        if let identityProvider { c.queryItems?.append(.init(name: "identity_provider", value: identityProvider)) }
        return SignInRequest(url: c.url!, verifier: verifier, state: state)
    }

    /// The page where a signed-in user adds a passkey (Touch ID / iCloud Keychain).
    public nonisolated var addPasskeyURL: URL {
        var c = URLComponents(string: "https://\(config.signInHost)/passkeys/add")!
        c.queryItems = [.init(name: "client_id", value: config.clientId), .init(name: "redirect_uri", value: CloudConfig.callback)]
        return c.url!
    }

    /// Finishes sign-in from the page's redirect. Returns the signed-in email address.
    @discardableResult
    public func completeSignIn(_ request: SignInRequest, callback: URL) async throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw CloudError.signIn(error, description: items.first(where: { $0.name == "error_description" })?.value)
        }
        guard items.first(where: { $0.name == "state" })?.value == request.state else { throw CloudError.failed("The sign-in didn't match. Try again.") }
        guard let code = items.first(where: { $0.name == "code" })?.value else { throw CloudError.failed("The sign-in page didn't finish.") }
        let tokens = try await token([
            "grant_type": "authorization_code", "client_id": config.clientId, "code": code,
            "redirect_uri": CloudConfig.callback, "code_verifier": request.verifier,
        ])
        guard let refresh = tokens["refresh_token"] as? String else { throw CloudError.failed("No sign-in was returned.") }
        refreshToken = refresh
        identityId = nil
        cached = nil
        try remember(tokens)
        onChange(refresh)
        return email ?? ""
    }

    /// The signed-in email (from the ID token), if known.
    public var email: String? {
        guard let token = idToken?.token else { return nil }
        return Self.claims(token)["email"] as? String
    }

    public func signOut() async {
        if let refreshToken {
            var req = URLRequest(url: URL(string: "https://\(config.signInHost)/oauth2/revoke")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Self.form(["token": refreshToken, "client_id": config.clientId])
            _ = try? await URLSession.shared.data(for: req)
        }
        refreshToken = nil
        idToken = nil
        identityId = nil
        cached = nil
        onChange(nil)
    }

    // MARK: AWS credentials

    /// Credentials for the browser APIs, refreshed as needed.
    public func credentials() async throws -> AWSCredentials {
        if let cached, cached.isFresh { return cached }
        let id = try await currentIDToken()
        let logins = [config.issuer: id]
        if identityId == nil {
            let r = try await cognitoIdentity("GetId", ["IdentityPoolId": config.identityPoolId, "Logins": logins])
            identityId = r["IdentityId"] as? String
        }
        guard let identityId else { throw CloudError.failed("The cloud account has no identity.") }
        let r = try await cognitoIdentity("GetCredentialsForIdentity", ["IdentityId": identityId, "Logins": logins])
        guard let c = r["Credentials"] as? [String: Any], let key = c["AccessKeyId"] as? String, let secret = c["SecretKey"] as? String else {
            throw CloudError.failed("AWS didn't return credentials.")
        }
        let expiry = (c["Expiration"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date().addingTimeInterval(3000)
        let creds = AWSCredentials(accessKeyId: key, secretAccessKey: secret, sessionToken: c["SessionToken"] as? String, expiration: expiry)
        cached = creds
        return creds
    }

    private func currentIDToken() async throws -> String {
        if let idToken, idToken.expires.timeIntervalSinceNow > 120 { return idToken.token }
        guard let refreshToken else { throw CloudError.signedOut }
        let tokens: [String: Any]
        do {
            tokens = try await token(["grant_type": "refresh_token", "client_id": config.clientId, "refresh_token": refreshToken])
        } catch CloudError.failed(let m) where m.contains("invalid_grant") {
            // The 30 days are up, or the sign-in was revoked.
            await signOut()
            throw CloudError.signedOut
        }
        try remember(tokens)
        return idToken!.token
    }

    private func remember(_ tokens: [String: Any]) throws {
        guard let id = tokens["id_token"] as? String else { throw CloudError.failed("No ID token was returned.") }
        let exp = (Self.claims(id)["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date().addingTimeInterval(3000)
        idToken = (id, exp)
    }

    // MARK: HTTP

    private func token(_ fields: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://\(config.signInHost)/oauth2/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.form(fields)
        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CloudError.failed("Sign-in failed (\(json["error"] as? String ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")).")
        }
        return json
    }

    private func cognitoIdentity(_ action: String, _ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://cognito-identity.\(config.region).amazonaws.com/")!)
        req.httpMethod = "POST"
        req.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        req.setValue("AWSCognitoIdentityService.\(action)", forHTTPHeaderField: "X-Amz-Target")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            if (json["__type"] as? String)?.contains("NotAuthorized") == true { throw CloudError.signedOut }
            throw CloudError.failed("AWS refused the sign-in: \(json["message"] as? String ?? json["__type"] as? String ?? "unknown error").")
        }
        return json
    }

    static func form(_ fields: [String: String]) -> Data {
        Data(fields.map { "\(SigV4.encode($0.key))=\(SigV4.encode($0.value))" }.sorted().joined(separator: "&").utf8)
    }

    static func claims(_ jwt: String) -> [String: Any] {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return [:] }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func randomURLSafe(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return Data(b).base64URL
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
