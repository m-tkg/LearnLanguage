import Foundation

/// URL から記事本文を抽出する。実装は素の URLSession 取得 → WKWebView 描画 → Gemini → Jina Reader の
/// 段階的フォールバック（Services/Extraction/ArticleContentExtractor）。
protocol ContentExtracting: Sendable {
    func extract(from url: URL) async throws -> ExtractedArticle
}

/// 記事本文をセグメントに分割し、各セグメントを指定レベルへ書き換える。
/// 実装は FoundationModels（Services/Generation）。多言語に備え言語コードを引数に取る。
protocol TextRewriting: Sendable {
    /// 抽出済み本文を 3〜4 セグメントに分割し、各セグメントを書き換える。
    /// - Parameters:
    ///   - text: 抽出済みプレーンテキスト（言語は問わない。対象言語と異なる場合は翻訳される）。
    ///   - level: 目標レベル。`.original` の場合は簡略化しない（翻訳は行う）。
    ///   - languageCode: 学習対象言語（BCP-47）＝出力言語。
    ///   - nativeLanguageCode: 学習者母語（用語集の訳語ターゲット, BCP-47）。
    func rewrite(
        text: String,
        level: ReadingLevel,
        languageCode: String,
        nativeLanguageCode: String
    ) async throws -> [RewrittenSegment]
}

/// 複数記事の本文をまとめて 1 リクエストで書き換える（レート上限対策）。実装は Gemini のみ
/// （オンデバイスは `TextRewriting.rewrite` で 1 記事ずつ処理する）。
protocol BatchRewriting: Sendable {
    func rewriteBatch(_ items: [RewriteBatchItem], nativeLanguageCode: String) async throws -> [[RewrittenSegment]?]
}

/// 短い視覚プロンプトからイラストを生成する。実装はクラウド（Gemini, Services/Imaging）。
/// iOS の ImageCreator は iOS 27 で notSupported のため、クラウド API に一本化している。
protocol IllustrationGenerating: Sendable {
    func illustrate(prompt: String) async -> IllustrationResult
}
