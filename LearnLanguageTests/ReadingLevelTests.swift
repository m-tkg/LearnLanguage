import XCTest
@testable import LearnLanguage

/// レベル（初級/中級/上級/超上級/オリジナル）の数値パラメータと指示文変換のテスト。
final class ReadingLevelTests: XCTestCase {

    func testVocabularyCapIncreasesWithLevel() {
        XCTAssertLessThan(ReadingLevel.beginner.parameters.vocabularyRankCap,
                          ReadingLevel.intermediate.parameters.vocabularyRankCap)
        XCTAssertLessThan(ReadingLevel.intermediate.parameters.vocabularyRankCap,
                          ReadingLevel.advanced.parameters.vocabularyRankCap)
        XCTAssertLessThan(ReadingLevel.advanced.parameters.vocabularyRankCap,
                          ReadingLevel.expert.parameters.vocabularyRankCap)
    }

    func testSentenceLengthIncreasesWithLevel() {
        XCTAssertLessThan(ReadingLevel.beginner.parameters.maxSentenceLength,
                          ReadingLevel.advanced.parameters.maxSentenceLength)
    }

    func testBeginnerDisallowsSubordinateClauses() {
        XCTAssertFalse(ReadingLevel.beginner.parameters.allowsSubordinateClauses)
        XCTAssertTrue(ReadingLevel.advanced.parameters.allowsSubordinateClauses)
    }

    func testInstructionsMentionNativeLanguage() {
        let text = ReadingLevel.intermediate.rewriteInstructions(languageCode: "en", nativeLanguageCode: "ja")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("ja"))
    }

    func testInstructionsIncludeVocabularyCap() {
        let level = ReadingLevel.beginner
        let text = level.rewriteInstructions(languageCode: "en", nativeLanguageCode: "ja")
        XCTAssertTrue(text.contains("\(level.parameters.vocabularyRankCap)"))
    }

    func testOriginalHasNoRewriteInstructions() {
        XCTAssertTrue(ReadingLevel.original.rewriteInstructions(languageCode: "en", nativeLanguageCode: "ja").isEmpty)
    }

    func testStorageRoundTrip() {
        for level in ReadingLevel.allCases {
            let restored = ReadingLevel(storageValue: level.storageValue, isOriginal: level == .original)
            XCTAssertEqual(restored, level)
        }
    }

    func testLegacyStorageValuesMapToExpert() {
        // 旧スキーマの大きな値（4〜10）は最上位の超上級に丸める。
        XCTAssertEqual(ReadingLevel(storageValue: 7, isOriginal: false), .expert)
        XCTAssertEqual(ReadingLevel(storageValue: 0, isOriginal: false), .original)
    }

    func testExpertIsListedAboveOriginalInPickers() {
        // ピッカー表示順: 初級 → 中級 → 上級 → 超上級 → オリジナル。
        XCTAssertEqual(ReadingLevel.allCases,
                       [.beginner, .intermediate, .advanced, .expert, .original])
    }
}
