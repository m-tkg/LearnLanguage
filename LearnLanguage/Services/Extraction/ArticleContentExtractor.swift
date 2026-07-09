import Foundation

/// 記事 URL から本文テキストを抽出する。段階的フォールバックの連鎖を編成する
/// （実際の取得ロジックは各 Fetcher に委譲）:
///   1. `DirectFetcher`         — 素の URLSession で直接取得（最速・第三者を経由しない）
///   2. `WebViewRenderer`       — 直接取得が薄い場合、WKWebView で JS 描画して再取得
///   3. `GeminiURLContextFetcher` — Gemini の url_context ツールで URL を読ませる
///   4. `JinaReaderFetcher`     — 最終手段として第三者リーダー（Jina）
///
/// どのモデルを使うか（`GeminiModel.current`）は Generation 層の設定なので、
/// Extraction 層の内側（各 Fetcher）からは依存させず、ここ（編成側）でだけ参照する。
struct ArticleContentExtractor: ContentExtracting {
    /// これ以上あれば「全文が取れた」とみなす閾値。未満なら JS 描画を試す。
    private static let fullArticleLength = 1500
    /// 直接取得がこの長さ以上あれば（薄くても）綺麗な本文として採用しうる。
    private static let minUsableLength = 100

    func extract(from url: URL) async throws -> ExtractedArticle {
        let direct = try? await DirectFetcher().fetch(from: url)

        // 1. 直接取得で全文が取れたら即採用（高速・第三者を経由しない）。
        if let direct, direct.text.count >= Self.fullArticleLength {
            return direct
        }

        // 2. 本文が薄い＝本文を JS で描画するページ。端末内の WKWebView で JS を実行して全文取得を試す。
        //    実 Safari エンジン＋利用者の回線なので、サーバー型リーダーより取れることがある。
        //    読み込みが終わらないページで無限待ちしないよう全体にタイムアウトを掛ける。
        if let rendered = try? await WebViewRenderer.withTimeout(30, { try await WebViewRenderer.fetch(url: url) }),
           rendered.text.count >= Self.fullArticleLength,
           rendered.text.count > (direct?.text.count ?? 0) {
            return rendered
        }

        // 3. Gemini（url_context）で URL を読ませて本文を取得する（キーがあれば）。
        if let viaGemini = try? await GeminiURLContextFetcher.fetch(url: url, model: GeminiModel.current),
           viaGemini.text.count > max(direct?.text.count ?? 0, Self.minUsableLength) {
            return viaGemini
        }

        // 4. それでも増えない場合は、直接取得の綺麗な本文（薄くても・ナビ除去済み）を使う。
        //    Jina はナビが混ざるため、ここでは使わない。
        if let direct, direct.text.count >= Self.minUsableLength {
            return direct
        }

        // 4. 直接取得がほぼ空（生 HTML に何も無い）→ 最終手段として第三者リーダー（Jina）。
        if let viaReader = try? await JinaReaderFetcher.fetch(from: url),
           viaReader.text.count > (direct?.text.count ?? 0) {
            return viaReader
        }

        // 5. すべて不十分。取れたものがあれば返し、無ければブロック扱い。
        if let direct, !direct.text.isEmpty { return direct }
        throw ExtractionError.blocked
    }
}
