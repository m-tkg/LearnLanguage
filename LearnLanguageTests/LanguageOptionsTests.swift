import XCTest
@testable import LearnLanguage

/// 言語一覧（読み上げ音声のある全言語の動的列挙）のテスト。
final class LanguageOptionsTests: XCTestCase {

    func testListContainsFeaturedLanguages() {
        let codes = LanguageOptions.all.map(\.code)
        for code in ["en", "ja", "zh", "ko", "es", "fr", "de"] {
            XCTAssertTrue(codes.contains(code), "\(code) は必ず一覧に含まれる")
        }
    }

    func testFeaturedLanguagesComeFirst() {
        let codes = LanguageOptions.all.map(\.code)
        XCTAssertEqual(Array(codes.prefix(2)), ["en", "ja"], "よく使う言語が先頭に固定される")
    }

    func testCodesAreUnique() {
        let codes = LanguageOptions.all.map(\.code)
        XCTAssertEqual(codes.count, Set(codes).count, "コードは重複しない")
    }

    func testNamesAreNativeNames() {
        XCTAssertEqual(LanguageOptions.name(for: "ja"), "日本語")
        XCTAssertEqual(LanguageOptions.name(for: "fr"), "Français")
    }

    func testUnknownCodeFallsBackToCode() {
        XCTAssertEqual(LanguageOptions.name(for: "zz-unknown"), "zz-unknown")
    }
}
