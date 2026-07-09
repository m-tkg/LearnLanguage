import XCTest
@testable import LearnLanguage

/// `GeminiClient`（3実装に分散していた Gemini HTTP クライアントの統一先）のテスト。
/// 認証エラー・1日無料枠上限が「待たずに即失敗」すること、テキスト抽出の基本動作を固定する。
final class GeminiClientTests: XCTestCase {

    // MARK: - firstText（純粋なロジック）

    func testFirstTextExtractsCandidateText() {
        let json = #"{"candidates":[{"content":{"parts":[{"text":"hello world"}]}}]}"#
        let data = Data(json.utf8)
        XCTAssertEqual(GeminiClient.firstText(from: data), "hello world")
    }

    func testFirstTextReturnsNilForEmptyCandidates() {
        let json = #"{"candidates":[]}"#
        XCTAssertNil(GeminiClient.firstText(from: Data(json.utf8)))
    }

    func testFirstTextReturnsNilForMalformedJSON() {
        XCTAssertNil(GeminiClient.firstText(from: Data("not json".utf8)))
    }

    // MARK: - send（HTTP は URLProtocol でモックし、待機を伴わない即失敗系のみ検証）

    struct DummyBody: Encodable { let x = 1 }

    func testNoKeyThrowsWithoutNetworkCall() async {
        MockURLProtocol.requestCount = 0
        do {
            _ = try await GeminiClient.send(model: "m", body: DummyBody(), apiKey: nil, session: MockURLProtocol.session)
            XCTFail("キー未設定なら必ず失敗するはず")
        } catch let error as GeminiClient.ClientError {
            guard case .noKey = error else { return XCTFail("noKey を期待") }
        } catch {
            XCTFail("想定外のエラー型: \(error)")
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 0, "キーが無ければリクエストを送らない")
    }

    func test401FailsImmediatelyWithoutRetry() async throws {
        MockURLProtocol.requestCount = 0
        MockURLProtocol.stub = { _ in (401, Data("{}".utf8)) }

        do {
            _ = try await GeminiClient.send(model: "m", body: DummyBody(), apiKey: "key", session: MockURLProtocol.session)
            XCTFail("401 は失敗するはず")
        } catch let error as GeminiClient.ClientError {
            guard case .api(let status, let message, _) = error else { return XCTFail("api エラーを期待") }
            XCTAssertEqual(status, 401)
            XCTAssertTrue(message.contains("APIキー"))
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "401 はリトライしない")
    }

    func testPerDayQuotaFailsImmediatelyWithoutRetry() async throws {
        MockURLProtocol.requestCount = 0
        let body = """
        {"error":{"message":"quota","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure",\
        "violations":[{"quotaId":"GenerateRequestsPerDayPerProjectPerModel-FreeTier"}]},\
        {"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"21s"}]}}
        """
        MockURLProtocol.stub = { _ in (429, Data(body.utf8)) }

        do {
            _ = try await GeminiClient.send(model: "m", body: DummyBody(), apiKey: "key", session: MockURLProtocol.session)
            XCTFail("PerDay 上限は失敗するはず")
        } catch let error as GeminiClient.ClientError {
            guard case .api(let status, let message, _) = error else { return XCTFail("api エラーを期待") }
            XCTAssertEqual(status, 429)
            XCTAssertTrue(message.contains("1日上限"))
        }
        // retryDelay(21s) は maxRetryDelay(65s) 未満だが、PerDay と判定できれば待っても回復しないため
        // 即座に諦める（21秒待ってリトライされていないことで確認する）。
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "PerDay 上限は retryDelay の長短に関わらずリトライしない")
    }

    func testSuccessReturnsBodyData() async throws {
        MockURLProtocol.requestCount = 0
        let expected = Data(#"{"ok":true}"#.utf8)
        MockURLProtocol.stub = { _ in (200, expected) }

        let data = try await GeminiClient.send(model: "m", body: DummyBody(), apiKey: "key", session: MockURLProtocol.session)
        XCTAssertEqual(data, expected)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testRequestUsesAPIKeyHeaderNotQueryString() async throws {
        MockURLProtocol.requestCount = 0
        var capturedRequest: URLRequest?
        MockURLProtocol.stub = { request in
            capturedRequest = request
            return (200, Data("{}".utf8))
        }

        _ = try await GeminiClient.send(model: "gemini-2.5-flash-lite", body: DummyBody(), apiKey: "secret-key", session: MockURLProtocol.session)

        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "x-goog-api-key"), "secret-key")
        XCTAssertFalse(capturedRequest?.url?.absoluteString.contains("secret-key") ?? true,
                       "キーはクエリに含めない（URL エンコード事故を避けるため）")
    }
}

// MARK: - URLProtocol モック

/// `URLSession` のネットワークをテスト内で差し替える。`stub` がリクエストを受けて
/// (statusCode, body) を返す。`requestCount` で呼び出し回数を検証できる。
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var stub: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requestCount = 0

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        let (status, data) = Self.stub?(request) ?? (200, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
