import CryptoKit
import Foundation

/// Short-lived AWS credentials (from the Cognito identity pool).
public struct AWSCredentials: Sendable, Equatable {
    public var accessKeyId: String
    public var secretAccessKey: String
    public var sessionToken: String?
    public var expiration: Date

    public init(accessKeyId: String, secretAccessKey: String, sessionToken: String?, expiration: Date) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.expiration = expiration
    }

    /// Still good for at least two more minutes.
    public var isFresh: Bool { expiration.timeIntervalSinceNow > 120 }
}

/// AWS Signature Version 4: signs a request (headers) for one service in one region.
public struct SigV4 {
    public var credentials: AWSCredentials
    public var region: String
    public var service: String

    public init(credentials: AWSCredentials, region: String, service: String) {
        self.credentials = credentials
        self.region = region
        self.service = service
    }

    /// Adds Host, X-Amz-Date, X-Amz-Security-Token and Authorization to `request`. A `wss://` URL is signed as the
    /// equivalent `https://` request (that's what AWS checks for WebSocket upgrades).
    public func sign(_ request: inout URLRequest, date: Date = Date()) {
        guard let url = request.url, let host = url.host else { return }
        let body = request.httpBody ?? Data()
        let amzDate = Self.timestamp(date)
        let day = String(amzDate.prefix(8))
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host

        var headers: [String: String] = [:]
        for (k, v) in request.allHTTPHeaderFields ?? [:] { headers[k.lowercased()] = v.trimmingCharacters(in: .whitespaces) }
        headers["host"] = hostHeader
        headers["x-amz-date"] = amzDate
        if let token = credentials.sessionToken { headers["x-amz-security-token"] = token }
        // Only these are signed; transport headers URLSession adds later (WebSocket keys, etc.) are not.
        let signedNames = headers.keys.filter { ["host", "content-type"].contains($0) || $0.hasPrefix("x-amz-") }.sorted()

        let canonical = [
            request.httpMethod ?? "GET",
            Self.canonicalPath(url),
            Self.canonicalQuery(url),
            signedNames.map { "\($0):\(headers[$0]!)\n" }.joined(),
            signedNames.joined(separator: ";"),
            Self.hex(SHA256.hash(data: body)),
        ].joined(separator: "\n")
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", amzDate, scope, Self.hex(SHA256.hash(data: Data(canonical.utf8)))].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8))
        for part in [day, region, service, "aws4_request"] { key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key))) }
        let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(toSign.utf8), using: key))

        request.setValue(hostHeader, forHTTPHeaderField: "Host")
        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        if let token = credentials.sessionToken { request.setValue(token, forHTTPHeaderField: "X-Amz-Security-Token") }
        request.setValue("AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(scope), SignedHeaders=\(signedNames.joined(separator: ";")), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
    }

    static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 { bytes.map { String(format: "%02x", $0) }.joined() }

    /// RFC 3986 encoding (AWS flavor: only A-Z a-z 0-9 - _ . ~ stay as they are).
    static func encode(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func canonicalPath(_ url: URL) -> String {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        guard !path.isEmpty else { return "/" }
        // The path is already encoded once; services other than S3 sign it encoded a second time.
        return path.split(separator: "/", omittingEmptySubsequences: false).map { encode(String($0)) }.joined(separator: "/")
    }

    static func canonicalQuery(_ url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let pairs: [(name: String, value: String)] = items.map { (encode($0.name), encode($0.value ?? "")) }
        let sorted = pairs.sorted { a, b in a.name == b.name ? a.value < b.value : a.name < b.name }
        return sorted.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    }
}
