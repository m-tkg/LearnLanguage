import XCTest
@testable import LearnLanguage

/// ステップ1のスモークテスト。純ロジックのテストは後続ステップ（レベル変換・強調・分割）で追加する。
final class SmokeTests: XCTestCase {
    func testArticleInitializesWithDefaults() {
        let article = LearningArticle(
            sourceURL: URL(string: "https://example.com")!,
            title: "Example",
            languageCode: "en",
            translationLanguageCode: "ja",
            targetLevel: 3
        )
        XCTAssertEqual(article.title, "Example")
        XCTAssertFalse(article.isFavorite)
        XCTAssertFalse(article.isOriginal)
        XCTAssertTrue(article.segments.isEmpty)
    }
}
