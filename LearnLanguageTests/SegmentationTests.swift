import XCTest
@testable import LearnLanguage

/// FoundationModelsRewriter の純ロジック（文分割・グルーピング・二分割）のテスト。
final class SegmentationTests: XCTestCase {

    func testSplitSentencesSeparatesEnglishSentences() {
        let text = "Octopuses are smart. They can hide. Scientists study them."
        let sentences = FoundationModelsRewriter.splitSentences(text, languageCode: "en")
        XCTAssertEqual(sentences.count, 3)
        XCTAssertEqual(sentences.first, "Octopuses are smart.")
    }

    func testGroupIntoSegmentsCapsAtFourAndPreservesOrder() {
        let sentences = (1...10).map { "S\($0)." }
        let groups = FoundationModelsRewriter.groupIntoSegments(sentences)
        XCTAssertEqual(groups.count, 4, "最大 4 グループ")
        XCTAssertEqual(groups.flatMap { $0 }, sentences, "全文を順序保持で覆う")
    }

    func testGroupIntoSegmentsFewSentences() {
        let groups = FoundationModelsRewriter.groupIntoSegments(["A.", "B."])
        XCTAssertEqual(groups.count, 2)
    }

    func testGroupIntoSegmentsEmpty() {
        XCTAssertTrue(FoundationModelsRewriter.groupIntoSegments([]).isEmpty)
    }

    func testGroupSizesAreBalanced() {
        // 10 文を 4 グループ → 3,3,2,2 の均等分割。
        let sentences = (1...10).map { "S\($0)." }
        let sizes = FoundationModelsRewriter.groupIntoSegments(sentences).map(\.count)
        XCTAssertEqual(sizes, [3, 3, 2, 2])
    }

    func testBisectSplitsRoughlyInHalf() {
        let text = "One. Two. Three. Four."
        let result = FoundationModelsRewriter.bisect(text, languageCode: "en")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.0, "One. Two.")
        XCTAssertEqual(result?.1, "Three. Four.")
    }

    func testBisectReturnsNilForSingleSentence() {
        XCTAssertNil(FoundationModelsRewriter.bisect("Only one sentence.", languageCode: "en"))
    }

    func testLooksDegenerateDetectsSchemaEcho() {
        XCTAssertTrue(FoundationModelsRewriter.looksDegenerate(
            #"Respond using compact JSON in a single line. {"type":"object","properties":{"text":"..."}}"#))
        XCTAssertTrue(FoundationModelsRewriter.looksDegenerate(
            "The rewritten passage using only allowed vocabulary. Preserve the original meaning."))
        XCTAssertTrue(FoundationModelsRewriter.looksDegenerate(
            #"{"advancedTerms": [], "imagePrompt": "box"}"#))
    }

    func testNormalRewriteIsNotDegenerate() {
        XCTAssertFalse(FoundationModelsRewriter.looksDegenerate(
            "Octopuses are smart animals. They can change color to hide from danger."))
    }
}
