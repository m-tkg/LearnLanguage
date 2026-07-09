import Foundation

/// 本文抽出（`ArticleContentExtractor` とその戦略の連鎖）で共有するエラー型。
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
