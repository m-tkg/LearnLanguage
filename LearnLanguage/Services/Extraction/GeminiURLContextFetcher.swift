import Foundation

/// Gemini の url_context ツールで URL を読ませ、本文テキストを取得する（段階的フォールバックの第三段）。
/// API キーは Keychain から。HTTP 送受信・リトライ・エラー分類は `GeminiClient` に委譲する
/// （tools 使用時は JSON モード非対応のためプレーンテキストで応答させ、1行目をタイトル・残りを本文として分ける）。
///
/// どのモデルを使うか（`GeminiModel.current`）は設定（Services/Generation 層）の知識であり、
/// この Fetcher はモデル名を引数で受け取るだけにして Extraction 層からの依存を作らない
/// （呼び出し側の `ArticleContentExtractor.extract` が編成する）。
enum GeminiURLContextFetcher {
    private static let minUsableLength = 100

    static func fetch(url: URL, model: String) async throws -> ExtractedArticle {
        let prompt = """
        Read the article at \(url.absoluteString) and extract its main content. \
        Respond in plain text as: the article title on the first line, then a blank line, \
        then the full article body text. Exclude navigation, related links, ads, and boilerplate.
        """
        let key = KeychainStore.get(account: KeychainStore.geminiAPIKeyAccount)
        let requestBody = URLContextRequest(
            contents: [.init(parts: [.init(text: prompt)])],
            tools: [.init()]
        )
        guard let data = try? await GeminiClient.send(model: model, body: requestBody, apiKey: key, timeout: 120),
              let raw = GeminiClient.firstText(from: data)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            throw ExtractionError.blocked
        }

        // 1 行目をタイトル、残りを本文として分ける。
        let lines = raw.components(separatedBy: "\n")
        let title = lines.first?.trimmingCharacters(in: .whitespaces)
        let bodyText = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = bodyText.isEmpty ? raw : bodyText
        guard text.count >= minUsableLength else { throw ExtractionError.emptyContent }

        return ExtractedArticle(
            title: (title?.isEmpty == false) ? title! : (url.host() ?? "記事"),
            text: text,
            languageCode: HTMLContentParser.detectLanguage(text)
        )
    }
}

// MARK: - Codable

private struct URLContextRequest: Encodable {
    struct Part: Encodable { let text: String }
    struct Content: Encodable { let parts: [Part] }
    struct Tool: Encodable {
        struct URLContext: Encodable {}
        var urlContext = URLContext()
        enum CodingKeys: String, CodingKey { case urlContext = "url_context" }
    }
    let contents: [Content]
    let tools: [Tool]
}
