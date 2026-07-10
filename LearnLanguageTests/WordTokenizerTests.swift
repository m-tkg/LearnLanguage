import XCTest
@testable import LearnLanguage

/// 本文の単語トークン分割（長押しで意味を引くための単位）のテスト。
final class WordTokenizerTests: XCTestCase {

    func testRunsReconstructOriginalText() {
        let text = "Octopuses are smart. They can solve puzzles!"
        let runs = WordTokenizer.runs(for: text)
        XCTAssertEqual(runs.map(\.text).joined(), text, "トークンを連結すると元の本文に戻る（欠落なし）")
    }

    func testEnglishWordsAreDetected() {
        let runs = WordTokenizer.runs(for: "Octopuses are smart.")
        let words = runs.filter(\.isWord).map(\.text)
        XCTAssertEqual(words, ["Octopuses", "are", "smart"])
        // 空白・句読点は単語ではない。
        XCTAssertTrue(runs.contains { !$0.isWord && $0.text == "." })
    }

    func testJapaneseWordsAreDetected() {
        let runs = WordTokenizer.runs(for: "タコは賢い動物です。")
        let words = runs.filter(\.isWord).map(\.text)
        XCTAssertTrue(words.contains("タコ"), "スペースの無い言語も NLTokenizer で分割できる: \(words)")
        XCTAssertEqual(runs.map(\.text).joined(), "タコは賢い動物です。")
    }

    func testApostropheStaysInsideWord() {
        let runs = WordTokenizer.runs(for: "It's Tom's book.")
        let words = runs.filter(\.isWord).map(\.text)
        XCTAssertTrue(words.contains("It's") || words.contains("It"), "アポストロフィ語が壊れない: \(words)")
        XCTAssertEqual(runs.map(\.text).joined(), "It's Tom's book.")
    }

    func testEmptyTextYieldsNoRuns() {
        XCTAssertTrue(WordTokenizer.runs(for: "").isEmpty)
    }
}
