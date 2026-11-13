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
        let verifier = EmailVerifier(secrets: secrets, ai: nil, pollInterval: 0.01) { _ in box }
        let res = await verifier.waitForVerification(senderHint: "greenhouse", since: since, timeout: 2, kind: .code, codeLength: 8)
        XCTAssertEqual(res?.code, "nE5Cx0Ky")
        XCTAssertEqual(res?.source, "pattern")
        XCTAssertTrue(box.messages[2].seen)
        XCTAssertFalse(box.messages[1].seen)
    }

    /// A code the user already opened on their phone is still found (version 0.3 only searched unread mail).
    func testFindsAlreadyReadMessages() async {
        let box = FakeMailbox([email("six_digit")])
        box.messages[0].seen = true
        var secrets = Secrets()
        (secrets.imapUser, secrets.imapPassword, secrets.imapHost) = ("jane@example.com", "x", "imap.example.com")
        let verifier = EmailVerifier(secrets: secrets, ai: nil, pollInterval: 0.01) { _ in box }
        let res = await verifier.waitForVerification(senderHint: "ashby", since: Date().addingTimeInterval(-5), timeout: 1, kind: .code)
        XCTAssertEqual(res?.code, "482913")
    }

    func testTimesOutAndUnconfigured() async {
        var secrets = Secrets()
        (secrets.imapUser, secrets.imapPassword, secrets.imapHost) = ("jane@example.com", "x", "imap.example.com")
        let box = FakeMailbox([email("other")])
        let verifier = EmailVerifier(secrets: secrets, ai: nil, pollInterval: 0.01) { _ in box }
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
