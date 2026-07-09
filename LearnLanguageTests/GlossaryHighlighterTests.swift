import XCTest
@testable import LearnLanguage

/// 本文中の超過語（用語集の surface）を検出してハイライト範囲を返すロジックのテスト（TDD）。
final class GlossaryHighlighterTests: XCTestCase {

    func testFindsSingleSurface() {
        let text = "Octopuses are remarkable animals."
        let ranges = GlossaryHighlighter.emphasisRanges(in: text, surfaces: ["remarkable"])
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(text[ranges[0]], "remarkable")
    }

    func testIsCaseInsensitive() {
        let text = "Remarkable things happen."
        let ranges = GlossaryHighlighter.emphasisRanges(in: text, surfaces: ["remarkable"])
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(text[ranges[0]], "Remarkable")
    }

    func testFindsMultipleOccurrences() {
        let text = "cat and cat and dog"
        let ranges = GlossaryHighlighter.emphasisRanges(in: text, surfaces: ["cat"])
        XCTAssertEqual(ranges.count, 2)
    }

    func testEmptySurfacesYieldsNoRanges() {
        XCTAssertTrue(GlossaryHighlighter.emphasisRanges(in: "anything", surfaces: []).isEmpty)
    }

    func testNoMatchYieldsNoRanges() {
        XCTAssertTrue(GlossaryHighlighter.emphasisRanges(in: "hello world", surfaces: ["xyz"]).isEmpty)
    }

    func testBuildsAttributedStringWithEmphasis() {
        // ハイライト対象の run に太字が適用され、非対象には適用されないこと。
        let attributed = GlossaryHighlighter.attributedString(
            for: "a remarkable b",
            surfaces: ["remarkable"]
        )
        let emphasized = attributed.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
        let joined = emphasized.map { String(attributed[$0.range].characters) }.joined()
        XCTAssertEqual(joined, "remarkable")
    }
}
