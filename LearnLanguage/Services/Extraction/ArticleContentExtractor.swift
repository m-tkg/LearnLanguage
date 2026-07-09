import Foundation
import NaturalLanguage
import WebKit

/// 記事 URL から本文テキストを抽出する。
/// 上位ディレクトリの Gogai（`ArticleContentFetcher`）の方式を踏襲:
/// 素の `URLSession`（ブラウザ偽装 UA を付けない）で HTML を取得し、正規表現で
/// `<article>`/`<main>` を優先抽出してタグを剥がす。WKWebView / Readability.js は使わない
/// （JS 実行に伴う Cookie バナー混入・アニメ非表示や、UA 偽装による Cloudflare 誤検知を避けられる）。
struct ArticleContentExtractor: ContentExtracting {
    enum ExtractionError: LocalizedError {
        case emptyContent
        case blocked
        case fetchFailed(Int)

        var errorDescription: String? {
            switch self {
            case .emptyContent: return "本文を取得できませんでした。"
            case .blocked: return "このサイトはボット対策（Cloudflare 等）により本文を取得できませんでした。別の記事URLでお試しください。"
            case .fetchFailed(let status): return "ページを取得できませんでした（HTTP \(status)）。"
            }
        }
    }

    /// これ以上あれば「全文が取れた」とみなす閾値。未満なら JS 描画を試す。
    private static let fullArticleLength = 1500
    /// 直接取得がこの長さ以上あれば（薄くても）綺麗な本文として採用しうる。
    private static let minUsableLength = 100

    func extract(from url: URL) async throws -> ExtractedArticle {
        let direct = try? await extractDirect(from: url)

        // 1. 直接取得で全文が取れたら即採用（高速・第三者を経由しない）。
        if let direct, direct.text.count >= Self.fullArticleLength {
            return direct
        }

        // 2. 本文が薄い＝本文を JS で描画するページ。端末内の WKWebView で JS を実行して全文取得を試す。
        //    実 Safari エンジン＋利用者の回線なので、サーバー型リーダーより取れることがある。
        //    読み込みが終わらないページで無限待ちしないよう全体にタイムアウトを掛ける。
        if let rendered = try? await Self.withTimeout(30, { try await Self.extractViaWebView(url: url) }),
           rendered.text.count >= Self.fullArticleLength,
           rendered.text.count > (direct?.text.count ?? 0) {
            return rendered
        }

        // 3. Gemini（url_context）で URL を読ませて本文を取得する（キーがあれば）。
        if let viaGemini = try? await Self.extractViaGemini(url: url),
           viaGemini.text.count > max(direct?.text.count ?? 0, Self.minUsableLength) {
            return viaGemini
        }

        // 4. それでも増えない場合は、直接取得の綺麗な本文（薄くても・ナビ除去済み）を使う。
        //    Jina はナビが混ざるため、ここでは使わない。
        if let direct, direct.text.count >= Self.minUsableLength {
            return direct
        }

        // 4. 直接取得がほぼ空（生 HTML に何も無い）→ 最終手段として第三者リーダー（Jina）。
        if let viaReader = try? await Self.extractViaReader(from: url),
           viaReader.text.count > (direct?.text.count ?? 0) {
            return viaReader
        }

        // 5. すべて不十分。取れたものがあれば返し、無ければブロック扱い。
        if let direct, !direct.text.isEmpty { return direct }
        throw ExtractionError.blocked
    }

    // MARK: - WKWebView（JS 描画）フォールバック

    /// WKWebView で JS を実行し、描画後の DOM から本文を取得する（本文を JS で描画するページ向け）。
    @MainActor
    static func extractViaWebView(url: URL) async throws -> ExtractedArticle {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 3000))
        webView.load(URLRequest(url: url, timeoutInterval: 30))

        // 読み込み完了イベントには頼らず（来ないページで無限待ちになるため）、描画後の DOM を
        // 1 秒ごとにポーリングする。`Task.sleep` はキャンセル（=タイムアウト）を尊重するので中断できる。
        var bestHTML = ""
        var stableCount = 0
        for _ in 0..<20 {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(1))
            _ = try? await webView.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight);")
            let raw = (try? await webView.evaluateJavaScript("document.documentElement.outerHTML")) ?? nil
            let html = raw as? String ?? ""
            if html.count > bestHTML.count {
                bestHTML = html
                stableCount = 0
            } else {
                stableCount += 1
            }
            if extractText(from: html).count >= 1500, stableCount >= 1 { break }
        }

        let text = extractText(from: bestHTML)
        guard !text.isEmpty else { throw ExtractionError.emptyContent }
        let title = extractTitle(from: bestHTML) ?? (url.host() ?? "記事")
        let lang = extractLang(from: bestHTML) ?? detectLanguage(text)
        return ExtractedArticle(title: title, text: text, languageCode: lang)
    }

    /// 指定秒数を超えたら中断する（読み込みが終わらない WKWebView 等の無限待ち対策）。
    nonisolated static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw ExtractionError.blocked
            }
            guard let result = try await group.next() else { throw ExtractionError.blocked }
            group.cancelAll()
            return result
        }
    }

    /// 記事 URL を直接取得して本文抽出する（Gogai 方式）。
    private func extractDirect(from url: URL) async throws -> ExtractedArticle {
        let (html, status) = try await Self.fetchHTML(from: url)
        let text = Self.extractText(from: html)
        let title = Self.extractTitle(from: html) ?? (url.host() ?? "記事")
        let lang = Self.extractLang(from: html) ?? Self.detectLanguage(text)

        if Self.looksBlocked(text: text, title: title) || status == 403 || status == 429 {
            throw ExtractionError.blocked
        }
        if status >= 400 { throw ExtractionError.fetchFailed(status) }
        guard !text.isEmpty else { throw ExtractionError.emptyContent }
        return ExtractedArticle(title: title, text: text, languageCode: lang)
    }

    // MARK: - Gemini（url_context）フォールバック

    /// Gemini の url_context ツールで URL を読ませ、本文テキストを取得する。API キーは Keychain から。
    static func extractViaGemini(url: URL, model: String = GeminiModel.current) async throws -> ExtractedArticle {
        let key = KeychainStore.get(account: KeychainStore.geminiAPIKeyAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else {
            throw ExtractionError.blocked
        }
        let endpoint = URL(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        )!

        let prompt = """
        Read the article at \(url.absoluteString) and extract its main content. \
        Respond in plain text as: the article title on the first line, then a blank line, \
        then the full article body text. Exclude navigation, related links, ads, and boilerplate.
        """
        let requestBody: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "tools": [["url_context": [String: String]()]],
        ]
        var request = URLRequest(url: endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw ExtractionError.blocked
        }
        let raw = parts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw ExtractionError.emptyContent }

        // 1 行目をタイトル、残りを本文として分ける。
        let lines = raw.components(separatedBy: "\n")
        let title = lines.first?.trimmingCharacters(in: .whitespaces)
        let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = body.isEmpty ? raw : body
        guard text.count >= minUsableLength else { throw ExtractionError.emptyContent }

        return ExtractedArticle(
            title: (title?.isEmpty == false) ? title! : (url.host() ?? "記事"),
            text: text,
            languageCode: detectLanguage(text)
        )
    }

    // MARK: - リーダー（Jina）フォールバック

    /// Jina Reader（r.jina.ai）経由で本文を取得する。JS 描画や Cloudflare を解決してくれる。
    static func extractViaReader(from url: URL, session: URLSession = .shared) async throws -> ExtractedArticle {
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
            languageCode: detectLanguage(cleaned)
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

    /// 本文から言語コードを推定する（抽出時に lang 属性が無い場合の補完）。
    static func detectLanguage(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    /// URL の HTML を取得する。4xx でもブロック検知のため本文を返す（本文の空判定は呼び出し側）。
    static func fetchHTML(from url: URL, session: URLSession = .shared) async throws -> (html: String, status: Int) {
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return (html, status)
    }

    // MARK: - 本文抽出（Gogai ArticleContentFetcher より移植）

    /// HTML からプレーンテキストを抽出する。script/style/noscript/head を中身ごと除去し、
    /// `<article>`/`<main>` があればそれを本文として使い、タグを剥がす。
    static func extractText(from html: String) -> String {
        var text = html
        for tag in ["script", "style", "noscript", "head"] {
            text = removeTag(tag, from: text)
        }
        // 本文コンテナ（article/main のうち本文量が最大の要素）を選ぶ。無ければページ全体。
        text = extractMainContent(from: text) ?? text
        // コンテナ内のナビ/ヘッダ/フッタ/サイドバー（関連記事）/フォームを除去して
        // ボイラープレートが本文に混ざるのを防ぐ。
        for tag in ["nav", "header", "footer", "aside", "form"] {
            text = removeTag(tag, from: text)
        }
        return stripHTML(text)
    }

    private static func removeTag(_ tag: String, from html: String) -> String {
        html.replacingOccurrences(
            of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>",
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    /// `<article>`/`<main>` の中から、タグ除去後の**テキスト量が最大**の要素を返す（200 字超）。
    /// HTML 長ではなくテキスト量で選ぶことで、マークアップの多い関連記事カード（`<article>`）に
    /// 惑わされず、本文を含む `<main>` 等を正しく選べる（例: 9to5mac のようなカード多用サイト）。
    private static func extractMainContent(from html: String) -> String? {
        var candidates: [String] = []
        for tag in ["article", "main"] {
            guard let regex = try? NSRegularExpression(
                pattern: "<\(tag)[^>]*>([\\s\\S]*?)</\(tag)>",
                options: .caseInsensitive
            ) else { continue }
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
            where match.numberOfRanges > 1 {
                candidates.append(ns.substring(with: match.range(at: 1)))
            }
        }
        let scored = candidates.map { (html: $0, textLength: stripHTML($0).count) }
        guard let best = scored.max(by: { $0.textLength < $1.textLength }), best.textLength > 200 else {
            return nil
        }
        return best.html
    }

    /// HTML タグ・エンティティ・数値文字参照を除去してプレーンテキスト化する。
    static func stripHTML(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
            "&nbsp;": " ", "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“",
            "&hellip;": "…", "&mldr;": "…", "&mdash;": "—", "&ndash;": "–",
        ]
        for (entity, char) in entities {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        text = decodeNumericEntities(text)
        return text
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 数値文字参照(&#NNN; / &#xHHHH;)をデコード。アイコンフォント用の私用領域は空にする。
    private static func decodeNumericEntities(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "&#x?[0-9a-fA-F]+;", options: .caseInsensitive) else {
            return text
        }
        let ns = text as NSString
        var result = ""
        var lastEnd = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            let token = ns.substring(with: match.range)
            if let scalar = decodeEntityScalar(token), !isPrivateUse(scalar) {
                result += String(Character(scalar))
            }
            lastEnd = match.range.location + match.range.length
        }
        result += ns.substring(from: lastEnd)
        return result
    }

    private static func decodeEntityScalar(_ token: String) -> Unicode.Scalar? {
        let inner = token.dropFirst(2).dropLast()
        let isHex = inner.hasPrefix("x") || inner.hasPrefix("X")
        let digits = isHex ? inner.dropFirst() : inner[...]
        guard let value = UInt32(digits, radix: isHex ? 16 : 10) else { return nil }
        return Unicode.Scalar(value)
    }

    private static func isPrivateUse(_ scalar: Unicode.Scalar) -> Bool {
        (0xE000...0xF8FF).contains(scalar.value)
            || (0xF0000...0xFFFFD).contains(scalar.value)
            || (0x100000...0x10FFFD).contains(scalar.value)
    }

    // MARK: - タイトル・言語

    /// og:title があれば優先、無ければ <title>。
    static func extractTitle(from html: String) -> String? {
        if let og = firstMatch(in: html,
                               pattern: "<meta[^>]+property=[\"']og:title[\"'][^>]*content=[\"']([^\"']+)[\"']") {
            let title = stripHTML(og).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        if let raw = firstMatch(in: html, pattern: "<title[^>]*>([\\s\\S]*?)</title>") {
            let title = stripHTML(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return nil
    }

    /// <html lang="xx"> の言語コード。
    static func extractLang(from html: String) -> String? {
        firstMatch(in: html, pattern: "<html[^>]+lang=[\"']([^\"']+)[\"']")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    // MARK: - ブロック検知

    /// Cloudflare 等のブロック/チャレンジ画面かどうかを推定する（短文＋定型句、または定型タイトル）。
    static func looksBlocked(text: String, title: String) -> Bool {
        let loweredTitle = title.lowercased()
        if loweredTitle.contains("attention required") || loweredTitle.contains("just a moment") {
            return true
        }
        let markers = [
            "you have been blocked",
            "please enable cookies",
            "checking your browser",
            "verify you are human",
            "verifying you are human",
            "enable javascript and cookies",
        ]
        let lowered = text.lowercased()
        let hasMarker = markers.contains { lowered.contains($0) }
        return hasMarker && text.count < 2000
    }
}
