import XCTest
@testable import LearnLanguage

/// 本文に混入したモデルの擬似タグ除去（sanitized）のテスト。
final class SanitizeTests: XCTestCase {

    func testRemovesAdvancedTermsTagAndRecoversWord() {
        let segment = RewrittenSegment(
            order: 0,
            text: "We used a tunnel with <advancedTerms surface='carbon dioxide' translation='二酸化炭素 (a gas)'/> gas and water.",
            advancedTerms: []
        )
        let cleaned = segment.sanitized()
        // タグは消え、surface が本文に戻る。
        XCTAssertFalse(cleaned.text.contains("<advancedTerms"))
        XCTAssertFalse(cleaned.text.contains("/>"))
        XCTAssertTrue(cleaned.text.contains("with carbon dioxide gas and water"))
        // 用語集に取り込まれる。
        XCTAssertTrue(cleaned.advancedTerms.contains { $0.surface == "carbon dioxide" && $0.translation.contains("二酸化炭素") })
    }

    func testDoesNotDuplicateExistingTerm() {
        let segment = RewrittenSegment(
            order: 0,
            text: "A <advancedTerms surface='cyborg' translation='サイボーグ'/> walked.",
            advancedTerms: [AdvancedTerm(surface: "cyborg", translation: "サイボーグ")]
        )
        let cleaned = segment.sanitized()
        XCTAssertEqual(cleaned.advancedTerms.filter { $0.surface == "cyborg" }.count, 1)
        XCTAssertTrue(cleaned.text.contains("A cyborg walked."))
    }

    func testStripsStrayTags() {
        let segment = RewrittenSegment(order: 0, text: "Hello <b>world</b> now.", advancedTerms: [])
        XCTAssertEqual(segment.sanitized().text, "Hello world now.")
    }

    func testPlainTextUnchanged() {
        let segment = RewrittenSegment(order: 0, text: "Octopuses are smart.", advancedTerms: [])
        XCTAssertEqual(segment.sanitized().text, "Octopuses are smart.")
    }
}
