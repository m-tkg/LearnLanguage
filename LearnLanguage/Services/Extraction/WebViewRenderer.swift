import Foundation
import WebKit

/// WKWebView で JS を実行し、描画後の DOM から本文を取得する（本文を JS で描画するページ向け）。
/// 段階的フォールバックの第二段。実 Safari エンジン＋利用者の回線で動くため、
/// サーバー型リーダーより取れることがある。
enum WebViewRenderer {
    @MainActor
    static func fetch(url: URL) async throws -> ExtractedArticle {
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
            if HTMLContentParser.extractText(from: html).count >= 1500, stableCount >= 1 { break }
        }

        let text = HTMLContentParser.extractText(from: bestHTML)
        guard !text.isEmpty else { throw ExtractionError.emptyContent }
        let title = HTMLContentParser.extractTitle(from: bestHTML) ?? (url.host() ?? "記事")
        let lang = HTMLContentParser.extractLang(from: bestHTML) ?? HTMLContentParser.detectLanguage(text)
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
}
