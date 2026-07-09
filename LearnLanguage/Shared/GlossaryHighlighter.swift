import Foundation

/// 本文中の超過語（用語集の surface）を検出し、強調表示用の範囲・AttributedString を作る。
///
/// モデルには装飾を出させず、表示時に本文を検索して強調する方針。屈折の激しい言語では
/// 単純な文字列一致が破綻しうるため、将来はレンマ/形態素マッチへ差し替える（本 API を境界にする）。
enum GlossaryHighlighter {

    /// 本文中の各 surface の出現範囲を（重複含め）返す。大文字小文字は区別しない。
    static func emphasisRanges(in text: String, surfaces: [String]) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        for surface in surfaces where !surface.isEmpty {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let found = text.range(of: surface,
                                         options: .caseInsensitive,
                                         range: searchStart..<text.endIndex) {
                ranges.append(found)
                searchStart = found.upperBound
            }
        }
        return ranges.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// 本文から、超過語を強調した AttributedString を作る。
    static func attributedString(for text: String, surfaces: [String]) -> AttributedString {
        var attributed = AttributedString(text)
        for range in emphasisRanges(in: text, surfaces: surfaces) {
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            let length = text.distance(from: range.lowerBound, to: range.upperBound)
            let lower = attributed.index(attributed.startIndex, offsetByCharacters: start)
            let upper = attributed.index(lower, offsetByCharacters: length)
            attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return attributed
    }
}
