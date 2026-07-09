import XCTest
@testable import LearnLanguage

/// イラスト生成まわりの純ロジック/分岐のテスト。
final class IllustrationTests: XCTestCase {

    func testPromptResolvePrefersImagePrompt() {
        let result = IllustrationPrompt.resolve(imagePrompt: "an octopus in the sea",
                                                fallbackText: "Some long body text here.")
        XCTAssertEqual(result, "an octopus in the sea")
    }

    func testPromptResolveFallsBackToTruncatedText() {
        let text = (1...40).map { "word\($0)" }.joined(separator: " ")
        let result = IllustrationPrompt.resolve(imagePrompt: nil, fallbackText: text)
        XCTAssertEqual(result.split(separator: " ").count, 25, "先頭25語に切り詰める")
    }

    func testPromptResolveEmptyImagePromptFallsBack() {
        let result = IllustrationPrompt.resolve(imagePrompt: "", fallbackText: "hello world")
        XCTAssertEqual(result, "hello world")
    }

    func testStyledPromptIncludesBasePrompt() {
        let styled = GeminiIllustrator.styledPrompt("a red apple")
        XCTAssertTrue(styled.hasPrefix("a red apple"))
        XCTAssertTrue(styled.localizedCaseInsensitiveContains("illustration"))
    }

    func testMissingAPIKeyReturnsFailure() async {
        let illustrator = GeminiIllustrator(apiKey: { nil })
        let result = await illustrator.illustrate(prompt: "a cat")
        guard case .failure(let reason) = result else {
            return XCTFail("キー未設定なら失敗するはず")
        }
        XCTAssertTrue(reason.contains("APIキー"))
    }

    // MARK: - Pollinations

    func testPollinationsStyledPromptIncludesBasePrompt() {
        let styled = PollinationsIllustrator.styledPrompt("a red apple")
        XCTAssertTrue(styled.hasPrefix("a red apple"))
        XCTAssertTrue(styled.localizedCaseInsensitiveContains("illustration"))
    }

    func testPollinationsURLIsWellFormed() {
        let url = PollinationsIllustrator.makeURL(prompt: "a cat on a mat", width: 768, height: 512)
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.host, "image.pollinations.ai")
        XCTAssertTrue(url?.path.hasPrefix("/prompt/") ?? false)
        let query = url?.query ?? ""
        XCTAssertTrue(query.contains("width=768"))
        XCTAssertTrue(query.contains("height=512"))
        XCTAssertTrue(query.contains("nologo=true"))
        // 空白がパスに含まれず、エンコードされていること。
        XCTAssertFalse(url?.absoluteString.contains(" ") ?? true)
    }

    func testDefaultProviderIsPollinations() {
        // 未設定時は無料の Pollinations を返す。
        UserDefaults.standard.removeObject(forKey: IllustratorFactory.providerDefaultsKey)
        XCTAssertTrue(IllustratorFactory.live() is PollinationsIllustrator)
    }
}
