import XCTest
@testable import Engine

final class EmailTests: XCTestCase {
    func testParseGreenhouseCode() {
        let e = MIME.parse(email("greenhouse"))
        XCTAssertEqual(e.sender, "no-reply@us.greenhouse-mail.io")
        XCTAssertEqual(e.subject, "Security code for your application to Initech")
        XCTAssertEqual(VerificationExtractor.code(in: e.text, length: 8), "nE5Cx0Ky")
    }

    func testSixDigitCodes() {
        XCTAssertEqual(VerificationExtractor.code(in: MIME.parse(email("six_digit")).text), "482913")
        XCTAssertEqual(VerificationExtractor.code(in: MIME.parse(email("six_digit_line")).text), "731004")
    }

    func testNoFalsePositives() {
        XCTAssertNil(VerificationExtractor.code(in: "Thanks for applying to LinkedIn's Security Engineer role. Your password manager is Complete.", length: 8))
        XCTAssertNil(VerificationExtractor.code(in: "Call 800-555-1234 or visit room 123456 tomorrow"))
    }

    func testWorkdayLink() {
        let e = MIME.parse(email("workday"))
        XCTAssertEqual(VerificationExtractor.link(in: e.links, domainHint: "myworkday"),
                       "https://initech.wd5.myworkdayjobs.com/en-US/careers/activate/abc123?token=z")
        XCTAssertNil(VerificationExtractor.link(in: [("Unsubscribe", "https://x.com/unsubscribe"), ("Home", "https://x.com")]))
    }

    /// Workday's email (Frost, 2026) links only its logo; the activation link is written out in the text.
    func testWorkdayActivationLinkWrittenOutInText() {
        let raw = """
            From: Frost Careers <frostbank@otp.workday.com>
            To: jane.doe@example.com
            Subject: Verify your candidate account
            Content-Type: text/html; charset="utf-8"
            MIME-Version: 1.0

            <html><body><a href="https://wd5.myworkday.com/frostbank"><img src="https://wd5.myworkday.com/logo.png" alt=""></a>
            <p>Click this link to confirm your email address and complete setup for your candidate account</p>
            <p>https://frostbank.wd5.myworkdayjobs.com/External/activate/6oetwi4e4a9k/?redirect=%2Fen-US%2FExternal%2Fjob%2FR261302%2Fapply</p>
            <p>The link will expire after 24 hours.</p></body></html>
            """.replacingOccurrences(of: "\n", with: "\r\n")
        let e = MIME.parse(Data(raw.utf8))
        XCTAssertEqual(VerificationExtractor.link(in: e.links, domainHint: "workday"),
                       "https://frostbank.wd5.myworkdayjobs.com/External/activate/6oetwi4e4a9k/?redirect=%2Fen-US%2FExternal%2Fjob%2FR261302%2Fapply")
        XCTAssertNil(VerificationExtractor.link(in: [("", "https://wd5.myworkday.com/frostbank")], domainHint: "workday"), "a logo isn't a confirmation link")
    }

    /// A "reset your password" email: its reset link, not the logo, the privacy page or a reference number.
    func testPasswordResetLink() async {
        let links = [("", "https://initech.wd5.myworkdayjobs.com/en-US/Careers"),
                     ("Reset Password", "https://initech.wd5.myworkdayjobs.com/en-US/Careers/passwordreset?token=abc123"),
                     ("Privacy", "https://www.workday.com/privacy")]
        XCTAssertEqual(VerificationExtractor.link(in: links, domainHint: "workday", reset: true),
                       "https://initech.wd5.myworkdayjobs.com/en-US/Careers/passwordreset?token=abc123")
        XCTAssertNil(VerificationExtractor.link(in: [("", "https://initech.example/activate?id=1")], reset: true), "an activation link doesn't reset")
        var secrets = Secrets()
        (secrets.imapUser, secrets.imapPassword, secrets.imapHost) = ("jane@example.com", "x", "imap.example.com")
        let raw = """
            From: Initech Careers <no-reply@initech.example>
            To: jane@example.com
            Subject: Reset your password
            Date: \(HandlerTests.rfc2822(Date()))
            Content-Type: text/plain; charset="utf-8"
            MIME-Version: 1.0

            Your reference number is 482913.
            Reset your password here: https://careers.initech.example/reset-password?token=zz9
            """.replacingOccurrences(of: "\n", with: "\r\n")
        let box = FakeMailbox([Data(raw.utf8)])
        let verifier = EmailVerifier(secrets: secrets, ai: nil, pollInterval: 0.01, openSession: { _ in box })
        let res = await verifier.waitForVerification(senderHint: "initech", since: Date().addingTimeInterval(-30), timeout: 1, kind: .reset)
        XCTAssertEqual(res?.url, "https://careers.initech.example/reset-password?token=zz9")
        XCTAssertNil(res?.code)
    }

    func testQuotedPrintableUnicodeMultipart() {
        let e = MIME.parse(email("unicode_multipart"))
        XCTAssertEqual(e.subject, "Votre code de vérification ✓")
        XCTAssertTrue(e.text.contains("Bonjour José — votre code de vérification est 905112."), e.text)
        XCTAssertTrue(e.text.contains("Ligne très longue Ligne très longue"), "soft line breaks are joined")
        XCTAssertEqual(VerificationExtractor.code(in: e.text), "905112")
        XCTAssertNotNil(e.date)
    }

    func testHTMLToText() {
        XCTAssertEqual(MIME.htmlToText("<style>p{}</style><p>Hello&nbsp;<b>World</b> &amp; you</p><p>Line&#8212;2</p>"), "Hello World & you\nLine—2")
    }

    func testWaitFiltersByTimeAndSender() async {
        let since = Date()
        let box = FakeMailbox([email("old", date: since.addingTimeInterval(-3600)), email("other"), email("greenhouse")])
        var secrets = Secrets()
        secrets.imapUser = "jane.doe@example.com"
        secrets.imapPassword = "abcdabcdabcdabcd"
        secrets.imapHost = "imap.example.com"
        let verifier = EmailVerifier(secrets: secrets, ai: nil, pollInterval: 0.01, openSession: { _ in box })
        let res = await verifier.waitForVerification(senderHint: "greenhouse", since: since, timeout: 2, kind: .code, codeLength: 8)
        XCTAssertEqual(res?.code, "nE5Cx0Ky")
        XCTAssertEqual(res?.source, "pattern")
        XCTAssertTrue(box.messages[2].seen)
        XCTAssertFalse(box.messages[1].seen)
    }

    /// A busy inbox: yesterday's hundreds of messages aren't downloaded while waiting (that took longer than the
    /// whole wait, so Workday's email was never read).
    func testOnlyNewMailIsDownloaded() async {
        let since = Date()
        let old = (0..<300).map { _ in email("other", date: since.addingTimeInterval(-20000)) }
        let box = FakeMailbox(old + [email("greenhouse")])
        for uid in 1...300 { box.arrived[uid] = since.addingTimeInterval(-20000) }
        box.arrived[301] = since.addingTimeInterval(5)
        var secrets = Secrets()
        (secrets.imapUser, secrets.imapPassword, secrets.imapHost) = ("jane@example.com", "x", "imap.example.com")
        let verifier = EmailVerifier(secrets: secrets, ai: nil, pollInterval: 0.01, openSession: { _ in box })
        let res = await verifier.waitForVerification(senderHint: "greenhouse", since: since, timeout: 2, kind: .code, codeLength: 8)
        XCTAssertEqual(res?.code, "nE5Cx0Ky")
        XCTAssertEqual(box.fetched, [301])
    }

    func testReadsWhenMailArrived() {
        let lines = [#"* 12 FETCH (UID 345 INTERNALDATE " 6-Nov-2026 21:30:00 +0000")"#,
                     #"* 13 FETCH (INTERNALDATE "16-Nov-2026 16:05:09 -0500" UID 346)"#, "* 14 FETCH (FLAGS (\\Seen))"]
        let got = IMAPClient.arrivals(lines)
        XCTAssertEqual(got.count, 2)
        XCTAssertEqual(got[345]?.timeIntervalSince1970, ISO8601DateFormatter().date(from: "2026-11-06T21:30:00Z")?.timeIntervalSince1970)
        XCTAssertEqual(got[346]?.timeIntervalSince1970, ISO8601DateFormatter().date(from: "2026-11-16T21:05:09Z")?.timeIntervalSince1970)
    }

    /// A code the user already opened on their phone is still found (version 0.3 only searched unread mail).
    func testFindsAlreadyReadMessages() async {
        let box = FakeMailbox([email("six_digit")])
        box.messages[0].seen = true
        var secrets = Secrets()
        (secrets.imapUser, secrets.imapPassword, secrets.imapHost) = ("jane@example.com", "x", "imap.example.com")
        let verifier = EmailVerifier(secrets: secrets, ai: nil, pollInterval: 0.01, openSession: { _ in box })
        let res = await verifier.waitForVerification(senderHint: "ashby", since: Date().addingTimeInterval(-5), timeout: 1, kind: .code)
        XCTAssertEqual(res?.code, "482913")
    }

    func testTimesOutAndUnconfigured() async {
        var secrets = Secrets()
        (secrets.imapUser, secrets.imapPassword, secrets.imapHost) = ("jane@example.com", "x", "imap.example.com")
        let box = FakeMailbox([email("other")])
        let verifier = EmailVerifier(secrets: secrets, ai: nil, pollInterval: 0.01, openSession: { _ in box })
        let res = await verifier.waitForVerification(senderHint: "workday", since: Date(), timeout: 0.2, kind: .link)
        XCTAssertNil(res)
        let none = await EmailVerifier(secrets: Secrets(), ai: nil).waitForVerification(senderHint: "x", since: Date(), timeout: 1)
        XCTAssertNil(none)
    }

    func testProviders() {
        XCTAssertEqual(EmailProviders.host(for: "Jane@Gmail.com"), "imap.gmail.com")
        XCTAssertEqual(EmailProviders.host(for: "x@icloud.com"), "imap.mail.me.com")
        XCTAssertNil(EmailProviders.host(for: "x@company.com"))
        XCTAssertEqual(EmailProviders.guide(for: "x@outlook.com")?.name, "Outlook.com")
    }

    func testIMAPQuoting() {
        XCTAssertEqual(IMAPClient.quote(#"pa"ss\word"#), #""pa\"ss\\word""#)
    }
}
