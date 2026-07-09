import Foundation

/// 素の `URLSession`（ブラウザ偽装 UA を付けない）で記事 URL を直接取得し、
/// `HTMLContentParser` で本文抽出する（Gogai `ArticleContentFetcher` 方式）。
/// 段階的フォールバックの第一段（最速・第三者を経由しない）。
struct DirectFetcher {
    func fetch(from url: URL) async throws -> ExtractedArticle {
        let (html, status) = try await Self.fetchHTML(from: url)
        let text = HTMLContentParser.extractText(from: html)
        let title = HTMLContentParser.extractTitle(from: html) ?? (url.host() ?? "記事")
        let lang = HTMLContentParser.extractLang(from: html) ?? HTMLContentParser.detectLanguage(text)

        if HTMLContentParser.looksBlocked(text: text, title: title) || status == 403 || status == 429 {
            throw ExtractionError.blocked
        }
        if status >= 400 { throw ExtractionError.fetchFailed(status) }
        guard !text.isEmpty else { throw ExtractionError.emptyContent }
        return ExtractedArticle(title: title, text: text, languageCode: lang)
    }

    /// URL の HTML を取得する。4xx でもブロック検知のため本文を返す（本文の空判定は呼び出し側）。
    static func fetchHTML(from url: URL, session: URLSession = .shared) async throws -> (html: String, status: Int) {
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return (html, status)
    }
}
