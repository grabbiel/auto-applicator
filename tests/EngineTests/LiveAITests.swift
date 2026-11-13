import XCTest
@testable import Engine

/// Uses the real on-device model when this Mac has Apple Intelligence (skipped otherwise).
final class LiveAITests: XCTestCase {
    func testAppleModelAnswersFormFields() async throws {
        guard let model = AppleIntelligence.makeModel() else { throw XCTSkip("Apple Intelligence unavailable: \(AppleIntelligence.status)") }
        let ai = AIService(model: model)
        let fields = [field("Will you require visa sponsorship now or in the future?", .radio, ["Yes", "No"], id: "a"),
                      field("Which cloud platform have you used the most?", .select, ["Select...", "AWS", "Azure", "GCP"], id: "b"),
                      field("Have you ever been convicted of a felony?", .radio, ["Yes", "No"], id: "c")]
        let start = Date()
        let answers = try await ai.answerFields(fields, profileText: ProfileText.render(Fixture.profile), job: Fixture.job, feedback: [:], memories: [])
        print("Apple model answered in \(String(format: "%.1f", Date().timeIntervalSince(start)))s:", answers)
        XCTAssertEqual(answers["a"]?.answer, "No")
        XCTAssertEqual(answers["b"]?.answer, "AWS")
        XCTAssertTrue(["Yes", "No"].contains(answers["c"]?.answer ?? ""), "answers stay within the options")
    }

    func testAppleModelWritesCoverLetter() async throws {
        guard let model = AppleIntelligence.makeModel() else { throw XCTSkip("Apple Intelligence unavailable") }
        let letter = try await AIService(model: model).coverLetter(profile: Fixture.profile, job: Fixture.job)
        print(letter)
        XCTAssertGreaterThan(letter.split(separator: " ").count, 80)
        XCTAssertTrue(letter.contains("Jane"))
    }
}
