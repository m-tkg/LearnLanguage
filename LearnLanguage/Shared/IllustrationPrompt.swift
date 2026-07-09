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

    /// 各イラストプロバイダ（Pollinations/Gemini）に共通するスタイル指示。
    /// プロバイダごとの差分（テキスト禁止の言い回し・アスペクト比指定等）は呼び出し側が付け足す。
    static let baseStyle = "2D Japanese anime style illustration, clean line art, cel shading, soft vibrant colors, "
        + "friendly and appealing, a detailed and descriptive scene that clearly depicts the situation "
        + "so the content is easy to understand at a glance"
}
