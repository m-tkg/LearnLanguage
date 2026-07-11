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

    // MARK: - Pollinations リトライ（530 等の一時エラー対策）

    /// リトライ検証用の Pollinations（ネットワークはモック・バックオフ待ちなし）。
    private func makePollinations() -> PollinationsIllustrator {
        PollinationsIllustrator(
            apiKey: { nil },
            session: MockURLProtocol.session,
            retryBaseDelay: 0
        )
    }

    func testPollinations530IsRetriedUntilSuccess() async {
        MockURLProtocol.requestCount = 0
        MockURLProtocol.responseHeaders = ["Content-Type": "image/jpeg"]
        defer { MockURLProtocol.responseHeaders = nil }
        // 2回 530（Cloudflare 一時障害）→ 3回目で成功。
        MockURLProtocol.stub = { _ in
            MockURLProtocol.requestCount <= 2 ? (530, Data()) : (200, Data([0xFF, 0xD8]))
        }

        let result = await makePollinations().illustrate(prompt: "a cat")

        guard case .success(let data) = result else {
            return XCTFail("530 はリトライで回復するはず: \(result)")
        }
        XCTAssertEqual(data, Data([0xFF, 0xD8]))
        XCTAssertEqual(MockURLProtocol.requestCount, 3)
    }

    func testPollinations404FailsWithoutRetry() async {
        MockURLProtocol.requestCount = 0
        MockURLProtocol.stub = { _ in (404, Data()) }

        let result = await makePollinations().illustrate(prompt: "a cat")

        guard case .failure = result else { return XCTFail("404 は失敗するはず") }
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "4xx（429以外）はリトライしない")
    }

    func testPollinationsPersistent530GivesUpAfterMaxAttempts() async {
        MockURLProtocol.requestCount = 0
        MockURLProtocol.stub = { _ in (530, Data()) }

        let result = await makePollinations().illustrate(prompt: "a cat")

        guard case .failure(let reason) = result else { return XCTFail("530 継続は最終的に失敗するはず") }
        XCTAssertTrue(reason.contains("530"), "エラー文言にステータスコードを含める: \(reason)")
        XCTAssertEqual(MockURLProtocol.requestCount, 4, "最大4回試行して諦める")
    }

    // MARK: - Cloudflare Workers AI

    private func makeCloudflare(
        accountID: String? = "acc-123",
        apiToken: String? = "token-xyz",
        model: CloudflareImageModel = .sdxlLightning
    ) -> CloudflareIllustrator {
        CloudflareIllustrator(
            model: model,
            accountID: { accountID },
            apiToken: { apiToken },
            session: MockURLProtocol.session,
            retryBaseDelay: 0
        )
    }

    /// URLProtocol 経由の送信 body は httpBodyStream に入るため、そこから読み出す。
    private static func bodyString(of request: URLRequest?) -> String {
        if let body = request?.httpBody { return String(decoding: body, as: UTF8.self) }
        guard let stream = request?.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return String(decoding: data, as: UTF8.self)
    }

    func testCloudflareMissingCredentialsFailsWithoutNetworkCall() async {
        MockURLProtocol.requestCount = 0

        let result = await makeCloudflare(accountID: nil, apiToken: nil).illustrate(prompt: "a cat")

        guard case .failure(let reason) = result else { return XCTFail("認証情報なしは失敗するはず") }
        XCTAssertTrue(reason.contains("Cloudflare"), "設定を促す文言: \(reason)")
        XCTAssertEqual(MockURLProtocol.requestCount, 0, "認証情報が無ければリクエストを送らない")
    }

    func testCloudflareSuccessDecodesBase64Image() async {
        MockURLProtocol.requestCount = 0
        let imageBytes = Data([0xFF, 0xD8, 0xFF])
        let body = #"{"result":{"image":"\#(imageBytes.base64EncodedString())"},"success":true}"#
        var captured: URLRequest?
        MockURLProtocol.stub = { request in
            captured = request
            return (200, Data(body.utf8))
        }

        let result = await makeCloudflare(model: .fluxSchnell).illustrate(prompt: "a cat")

        guard case .success(let data) = result else { return XCTFail("成功応答をデコードできるはず: \(result)") }
        XCTAssertEqual(data, imageBytes)
        let url = captured?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("/accounts/acc-123/ai/run/"), "Account ID がパスに入る: \(url)")
        XCTAssertTrue(url.contains("flux-1-schnell"), "選択したモデルを使う: \(url)")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer token-xyz")
    }

    func testCloudflareBinaryImageResponseIsAccepted() async {
        MockURLProtocol.requestCount = 0
        MockURLProtocol.responseHeaders = ["Content-Type": "image/png"]
        defer { MockURLProtocol.responseHeaders = nil }
        let imageBytes = Data([0x89, 0x50, 0x4E, 0x47])
        var captured: URLRequest?
        MockURLProtocol.stub = { request in
            captured = request
            return (200, imageBytes)
        }

        let result = await makeCloudflare(model: .sdxlLightning).illustrate(prompt: "a cat")

        guard case .success(let data) = result else {
            return XCTFail("バイナリ画像応答（SDXL 等）を受理するはず: \(result)")
        }
        XCTAssertEqual(data, imageBytes)
        let url = captured?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("stable-diffusion-xl-lightning"), "選択したモデルが URL に入る: \(url)")
    }

    func testCloudflareFluxRequestIncludesSteps() async {
        MockURLProtocol.requestCount = 0
        let body = #"{"result":{"image":"\#(Data([0x01]).base64EncodedString())"},"success":true}"#
        var captured: URLRequest?
        MockURLProtocol.stub = { request in
            captured = request
            return (200, Data(body.utf8))
        }

        _ = await makeCloudflare(model: .fluxSchnell).illustrate(prompt: "a cat")

        let sent = Self.bodyString(of: captured)
        XCTAssertTrue(sent.contains(#""steps":4"#), "FLUX schnell は 4 ステップ（蒸留モデルの推奨値）を明示する: \(sent)")
    }

    func testCloudflareSDXLRequestOmitsSteps() async {
        MockURLProtocol.requestCount = 0
        MockURLProtocol.responseHeaders = ["Content-Type": "image/png"]
        defer { MockURLProtocol.responseHeaders = nil }
        var captured: URLRequest?
        MockURLProtocol.stub = { request in
            captured = request
            return (200, Data([0x01]))
        }

        _ = await makeCloudflare(model: .sdxlLightning).illustrate(prompt: "a cat")

        let sent = Self.bodyString(of: captured)
        XCTAssertFalse(sent.contains("steps"), "SDXL Lightning は steps 非対応のため送らない: \(sent)")
        XCTAssertTrue(sent.contains("a cat"), "プロンプトは送る: \(sent)")
    }

    // MARK: - Cloudflare モデル選択（設定）

    func testCloudflareImageModelDefaultIsSDXLLightning() {
        UserDefaults.standard.removeObject(forKey: CloudflareImageModel.defaultsKey)
        XCTAssertEqual(CloudflareImageModel.current, .sdxlLightning, "未設定時は無料枠を消費しないモデル")
    }

    func testCloudflareImageModelReadsSelectionFromDefaults() {
        UserDefaults.standard.set(CloudflareImageModel.fluxSchnell.rawValue, forKey: CloudflareImageModel.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: CloudflareImageModel.defaultsKey) }
        XCTAssertEqual(CloudflareImageModel.current, .fluxSchnell)
    }

    func testFactoryUsesSelectedCloudflareModel() {
        UserDefaults.standard.set(ImageProvider.cloudflare.rawValue, forKey: IllustratorFactory.providerDefaultsKey)
        UserDefaults.standard.set(CloudflareImageModel.fluxSchnell.rawValue, forKey: CloudflareImageModel.defaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: IllustratorFactory.providerDefaultsKey)
            UserDefaults.standard.removeObject(forKey: CloudflareImageModel.defaultsKey)
        }
        let illustrator = IllustratorFactory.live() as? CloudflareIllustrator
        XCTAssertEqual(illustrator?.model, .fluxSchnell, "設定で選んだモデルが factory から渡される")
    }

    func testCloudflare5xxIsRetriedUntilSuccess() async {
        MockURLProtocol.requestCount = 0
        let body = #"{"result":{"image":"\#(Data([0x01]).base64EncodedString())"},"success":true}"#
        MockURLProtocol.stub = { _ in
            MockURLProtocol.requestCount <= 2 ? (503, Data()) : (200, Data(body.utf8))
        }

        let result = await makeCloudflare().illustrate(prompt: "a cat")

        guard case .success = result else { return XCTFail("5xx はリトライで回復するはず: \(result)") }
        XCTAssertEqual(MockURLProtocol.requestCount, 3)
    }

    func testCloudflareAuthErrorFailsWithoutRetry() async {
        MockURLProtocol.requestCount = 0
        MockURLProtocol.stub = { _ in (403, Data(#"{"success":false,"errors":[{"message":"Authentication error"}]}"#.utf8)) }

        let result = await makeCloudflare().illustrate(prompt: "a cat")

        guard case .failure = result else { return XCTFail("403 は失敗するはず") }
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "認証エラーはリトライしない")
    }
}
