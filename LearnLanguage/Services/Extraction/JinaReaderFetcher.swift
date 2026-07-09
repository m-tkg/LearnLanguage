import Foundation

/// Jina Reader（r.jina.ai）経由で本文を取得する（段階的フォールバックの最終段）。
/// JS 描画や Cloudflare を解決してくれる第三者サービス。第三者に URL が渡る点に注意。
enum JinaReaderFetcher {
    static func fetch(from url: URL, session: URLSession = .shared) async throws -> ExtractedArticle {
        guard let readerURL = URL(string: "https://r.jina.ai/" + url.absoluteString) else {
            throw ExtractionError.blocked
        }
        var request = URLRequest(url: readerURL, timeoutInterval: 60)
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let body = String(data: data, encoding: .utf8), !body.isEmpty else {
            throw ExtractionError.blocked
        }
        let (title, content) = parseReaderResponse(body)
        let cleaned = cleanMarkdown(content)
        guard cleaned.count >= 100 else { throw ExtractionError.emptyContent }
        return ExtractedArticle(
            title: title ?? (url.host() ?? "記事"),
            text: cleaned,
            languageCode: HTMLContentParser.detectLanguage(cleaned)
        )
    }

    /// Jina Reader の応答（"Title: ..." / "Markdown Content:" 形式）を分解する。
    static func parseReaderResponse(_ body: String) -> (title: String?, content: String) {
        let lines = body.components(separatedBy: "\n")
        var title: String?
        var contentStart: Int?
        for (index, line) in lines.enumerated() {
            if title == nil, line.hasPrefix("Title:") {
                title = line.dropFirst("Title:".count).trimmingCharacters(in: .whitespaces)
            }
            if line.hasPrefix("Markdown Content:") {
                contentStart = index + 1
                break
            }
        }
        let content: String
        if let start = contentStart {
            content = lines[start...].joined(separator: "\n")
        } else {
            content = body
        }
        return (title?.isEmpty == false ? title : nil,
                content.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Markdown を軽くプレーンテキスト化する（画像除去・リンクはテキスト化・見出し記号除去）。
    static func cleanMarkdown(_ markdown: String) -> String {
        var text = markdown
        let replacements: [(String, String)] = [
            ("!\\[[^\\]]*\\]\\([^)]*\\)", ""),          // 画像
            ("\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),         // リンク → テキスト
            ("(?m)^#{1,6}\\s*", ""),                       // 見出し
            ("(?m)^>\\s*", ""),                            // 引用
            ("(?m)^[-*+]\\s+", ""),                       // 箇条書き記号
            ("[*_`]", ""),                                  // 強調/コード記号
            ("\\n{3,}", "\n\n"),                           // 連続空行
        ]
        for (pattern, replacement) in replacements {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
