import Foundation

/// 本文抽出の結果（フレームワーク非依存の値型）。
struct ExtractedArticle: Sendable, Equatable {
    var title: String
    var text: String
    /// 抽出元から判定した言語（BCP-47）。判定できなければ nil。
    var languageCode: String?
}

/// レベル書き換え後の 1 セグメント。永続化前の中間表現。
struct RewrittenSegment: Sendable, Equatable {
    var order: Int
    var text: String
    var advancedTerms: [AdvancedTerm]
    /// Image Playground 用の短い視覚的プロンプト（省略可）。
    var imagePrompt: String = ""

    /// モデルが本文に埋め込んでしまった `<advancedTerms surface='X' translation='Y'/>` 等の
    /// 擬似タグを除去する。surface は本文に戻し、用語集にも取り込む。他の残存タグも剥がす。
    func sanitized() -> RewrittenSegment {
        var terms = advancedTerms
        var result = ""
        let ns = text as NSString
        if let tagRegex = try? NSRegularExpression(pattern: "<advancedTerms\\b[^>]*>", options: .caseInsensitive) {
            var lastEnd = 0
            for match in tagRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
                let tag = ns.substring(with: match.range)
                if let surface = Self.attribute("surface", in: tag) {
                    result += surface
                    let translation = Self.attribute("translation", in: tag) ?? ""
                    if !translation.isEmpty, !terms.contains(where: { $0.surface == surface }) {
                        terms.append(AdvancedTerm(surface: surface, translation: translation))
                    }
                }
                lastEnd = match.range.location + match.range.length
            }
            result += ns.substring(from: lastEnd)
        } else {
            result = text
        }
        // 残った他のタグを剥がし、余分な空白を整える。
        result = result
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return RewrittenSegment(order: order, text: result, advancedTerms: terms, imagePrompt: imagePrompt)
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: name + "\\s*=\\s*['\"]([^'\"]*)['\"]", options: .caseInsensitive
        ) else { return nil }
        let ns = tag as NSString
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }
}

/// レベルを超えてやむを得ず使った語と母語訳。
struct AdvancedTerm: Sendable, Equatable {
    var surface: String
    var translation: String
}

/// イラスト生成の結果。失敗時は理由を保持し、UI に表示する。
enum IllustrationResult: Sendable, Equatable {
    case success(Data)
    case failure(reason: String)
}

/// バッチ書き換えの 1 件分（抽出済み本文＋目標レベル＋記事言語）。
struct RewriteBatchItem: Sendable, Equatable {
    var text: String
    var level: ReadingLevel
    var languageCode: String
}
