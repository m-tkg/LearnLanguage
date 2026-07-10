import Foundation
import NaturalLanguage

/// 本文を「単語」と「それ以外（空白・句読点）」の連続した run に分解する。
/// 長押しで意味を引ける単位（単語）を切り出しつつ、連結すると元の本文に完全に戻ることを保証する。
/// NLTokenizer を使うため、スペースで区切らない言語（日本語・中国語等）でも分割できる。
enum WordTokenizer {
    struct Run: Equatable, Identifiable {
        let id: Int
        let text: String
        let isWord: Bool
    }

    static func runs(for text: String) -> [Run] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text

        var runs: [Run] = []
        var cursor = text.startIndex
        var id = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            // 直前の単語との間（空白・句読点など）を非単語 run として保持する。
            if cursor < range.lowerBound {
                runs.append(Run(id: id, text: String(text[cursor..<range.lowerBound]), isWord: false))
                id += 1
            }
            runs.append(Run(id: id, text: String(text[range]), isWord: true))
            id += 1
            cursor = range.upperBound
            return true
        }
        // 末尾の残り（句読点等）。
        if cursor < text.endIndex {
            runs.append(Run(id: id, text: String(text[cursor...]), isWord: false))
        }
        return runs
    }
}
