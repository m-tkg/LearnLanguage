import Foundation

/// セグメントからイラスト生成用のプロンプトを決める共通ロジック。
/// 生成済みの短い視覚プロンプトを優先し、無ければ本文の先頭を短く切り出す。
enum IllustrationPrompt {
    static func resolve(imagePrompt: String?, fallbackText: String) -> String {
        if let imagePrompt, !imagePrompt.isEmpty { return imagePrompt }
        return fallbackText
            .split(whereSeparator: { $0 == " " || $0.isNewline })
            .prefix(25)
            .joined(separator: " ")
    }
}
