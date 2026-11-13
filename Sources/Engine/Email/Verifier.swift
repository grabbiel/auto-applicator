import Foundation

public struct VerificationResult: Sendable, Equatable {
    public var code: String?
    public var url: String?
    public var subject: String
    public var sender: String
    public var source: String  // "pattern" or "ai"
}

public enum VerificationKind: Sendable { case code, link, any }

/// Pulls verification codes and confirmation links out of emails.
public enum VerificationExtractor {
    static let codeKeywords = Regex(#"\b(security code|verification code|one[- ]time (pass)?code|passcode|otp|code)\b"#)
    static let wordlike: Set<String> = ["linkedin", "password", "security", "workday", "required", "position", "personal", "complete"]

    static func looksLikeCode(_ t: String) -> Bool {
        if wordlike.contains(t.lowercased()) { return false }
        let hasDigit = t.contains { $0.isNumber }, hasAlpha = t.contains { $0.isLetter }
        let uppers = t.dropFirst().filter(\.isUppercase).count
        let isUpper = t.contains { $0.isLetter } && t == t.uppercased()
        return (hasDigit && hasAlpha) || (uppers >= 2 && t.contains { $0.isLowercase }) || isUpper
    }

    static func isAlnum(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }
    static func isDigits(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber } }

    /// Finds a one-time code. length 8 → Greenhouse-style letters and digits; 6 / nil → numeric codes first.
    public static func code(in text: String, length: Int? = nil) -> String? {
        let lengths = length.map { [$0] } ?? [6, 8]
        let lines = text.components(separatedBy: .newlines).map { $0.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "*")).trimmed }
        for n in lengths {
            let numericOnly = n == 6 && length == nil
            // 1) "code: XXXX" / "application: XXXX"
            let label = Regex(#"(?:code|application|passcode|otp|pin)\s*(?:is|:|-)\s*\**\s*([A-Za-z0-9]{\#(n)})\b"#)
            for tok in label.allMatches(text, group: 1) {
                if numericOnly ? isDigits(tok) : (isDigits(tok) || looksLikeCode(tok)) { return tok }
            }
            // 2) a line that is only the code ("123 456" too), within 4 lines of a code keyword
            let keywordLines = lines.indices.filter { codeKeywords.matches(lines[$0]) }
            for (i, line) in lines.enumerated() {
                let compact = Regex(#"^\d{3} \d{3}$"#, []).matches(line) ? line.replacingOccurrences(of: " ", with: "") : line
                guard compact.count == n, isAlnum(compact) else { continue }
                if numericOnly && !isDigits(compact) { continue }
                if !isDigits(compact) && !looksLikeCode(compact) { continue }
                if keywordLines.contains(where: { abs(i - $0) <= 4 }) { return compact }
            }
            // 3) six digits right after a keyword
            if n == 6, let g = Regex(#"(?:code|otp|passcode|pin)\D{0,40}?(?<!\d)(\d{6})(?!\d)"#).firstGroups(text), let c = g[1] { return c }
            // 4) a token near a mention of a code
            if !numericOnly {
                let ns = text as NSString
                for m in codeKeywords.re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    let window = ns.substring(with: NSRange(location: m.range.location, length: min(ns.length - m.range.location, m.range.length + 160)))
                    for tok in Regex(#"(?<![A-Za-z0-9])([A-Za-z0-9]{\#(n)})(?![A-Za-z0-9])"#, []).allMatches(window, group: 1) where looksLikeCode(tok) {
                        return tok
                    }
                }
            }
        }
        return nil
    }

    static let linkGood = Regex(#"verif|confirm|activat|validat|magic|sign[-_ ]?in|login|token=|email_verification"#)
    static let linkBad = Regex(#"unsubscribe|privacy|terms|preferences|help|support|facebook|twitter|linkedin\.com/company|mailto:"#)

    public static func link(in links: [(String, String)], domainHint: String = "") -> String? {
        var best: (Int, String)?
        for (text, href) in links {
            guard href.lowercased().hasPrefix("http"), !linkBad.matches(href) else { continue }
            var score = 0
            if linkGood.matches(href) { score += 2 }
            if linkGood.matches(text) { score += 3 }
            if !domainHint.isEmpty && href.lowercased().contains(domainHint.lowercased()) { score += 2 }
            if href.lowercased().contains("workday") { score += 1 }
            if score >= 3, best == nil || score > best!.0 { best = (score, href) }
        }
        return best?.1
    }

    static func matchesHint(_ e: ParsedEmail, _ hint: String) -> Bool {
        let parts = hint.split(separator: "|").map { String($0).trimmed.lowercased() }.filter { !$0.isEmpty }
        return parts.isEmpty || parts.contains { e.haystack.contains($0) }
    }
}

/// An open inbox (IMAP in the app; a stand-in in tests).
public protocol MailSession: AnyObject, Sendable {
    func refresh() async throws
    /// UIDs of messages received on or after the day of `date`, newest first.
    func uids(since date: Date) async throws -> [Int]
    func fetch(uid: Int) async throws -> Data?
    func markSeen(uid: Int) async throws
    func unseenCount() async throws -> Int
    func close()
}

extension IMAPClient: MailSession {
    func refresh() async throws { try await command("NOOP") }
    func uids(since date: Date) async throws -> [Int] { try await searchSince(date) }
}

/// Watches the user's inbox for the code or link a job site just emailed.
public final class EmailVerifier: @unchecked Sendable {
    let secrets: Secrets
    let ai: AIService?
    let pollInterval: TimeInterval
    let openSession: @Sendable (Secrets) async throws -> MailSession

    public init(secrets: Secrets, ai: AIService?, pollInterval: TimeInterval = 4,
                openSession: (@Sendable (Secrets) async throws -> MailSession)? = nil) {
        self.secrets = secrets
        self.ai = ai
        self.pollInterval = pollInterval
        self.openSession = openSession ?? { secrets in
            let client = IMAPClient(host: secrets.imapHost, port: secrets.imapPort)
            try await client.open()
            try await client.login(user: secrets.imapUser, password: secrets.imapPassword.replacingOccurrences(of: " ", with: ""))
            try await client.select()
            return client
        }
    }

    public var configured: Bool { secrets.emailConfigured }

    /// Logs in and returns the number of unread messages (to confirm the settings work).
    public func testConnection() async throws -> Int {
        let session = try await openSession(secrets)
        defer { session.close() }
        return try await session.unseenCount()
    }

    /// Waits for a message newer than `since` from a sender matching `senderHint` ("greenhouse|example.com") that
    /// contains a code or link. Version 0.3 only looked at unread mail, so a code already opened on the user's phone
    /// was missed; this looks at every recent message.
    public func waitForVerification(senderHint: String, since: Date, timeout: TimeInterval, kind: VerificationKind = .any,
                                    codeLength: Int? = nil) async -> VerificationResult? {
        guard configured else {
            Log.warn("Email isn't set up; can't read the verification email.")
            return nil
        }
        let session: MailSession
        do { session = try await openSession(secrets) } catch {
            Log.warn("Couldn't open the inbox: \(error.localizedDescription)")
            return nil
        }
        defer { session.close() }
        var examined = Set<Int>()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !Task.isCancelled {
            do {
                try await session.refresh()
                for uid in try await session.uids(since: since) where !examined.contains(uid) {
                    examined.insert(uid)
                    guard let raw = try await session.fetch(uid: uid) else { continue }
                    let parsed = MIME.parse(raw)
                    if let d = parsed.date, d < since.addingTimeInterval(-120) { continue }
                    guard VerificationExtractor.matchesHint(parsed, senderHint) else { continue }
                    let domain = String(senderHint.split(separator: "|").first ?? "")
                    if let result = await extract(parsed, kind: kind, codeLength: codeLength, domainHint: domain) {
                        try? await session.markSeen(uid: uid)
                        Log.info("Verification email found: \"\(parsed.subject)\" from \(parsed.sender)")
                        return result
                    }
                }
            } catch {
                Log.warn("Inbox check failed: \(error.localizedDescription)")
                return nil
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return nil
    }

    func extract(_ e: ParsedEmail, kind: VerificationKind, codeLength: Int?, domainHint: String) async -> VerificationResult? {
        func satisfied(_ code: String?, _ url: String?) -> Bool {
            switch kind {
            case .code: code != nil
            case .link: url != nil
            case .any: code != nil || url != nil
            }
        }
        let code = kind == .link ? nil : VerificationExtractor.code(in: "\(e.subject)\n\(e.text)", length: codeLength)
        let url = kind == .code ? nil : VerificationExtractor.link(in: e.links, domainHint: domainHint)
        if satisfied(code, url) { return VerificationResult(code: code, url: url, subject: e.subject, sender: e.sender, source: "pattern") }
        guard let ai else { return nil }
        guard let found = try? await ai.extractVerification(e) else { return nil }
        var aiCode = found.code.flatMap { Regex(#"^[A-Za-z0-9]{4,10}$"#, []).fullMatch($0) ? $0 : nil }
        if let c = aiCode, let n = codeLength, c.count != n { aiCode = nil }
        // never trust a link the AI made up
        let aiURL = found.url.flatMap { u in e.links.contains { $0.1 == u } ? u : nil }
        return satisfied(aiCode, aiURL) ? VerificationResult(code: aiCode, url: aiURL, subject: e.subject, sender: e.sender, source: "ai") : nil
    }
}
