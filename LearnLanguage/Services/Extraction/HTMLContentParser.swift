import Foundation
import NaturalLanguage

/// HTML から本文テキストを抜き出す純関数群（Gogai `ArticleContentFetcher` より移植）。
/// ネットワーク I/O を持たないため、どの Fetcher（直接取得・WKWebView 描画等）からも使える。
enum HTMLContentParser {
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

    // MARK: - 言語判定

    /// 本文から言語コードを推定する（抽出時に lang 属性が無い場合の補完）。
    static func detectLanguage(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }
}
