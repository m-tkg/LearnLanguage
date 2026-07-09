import Foundation
import SwiftData

/// 記事の処理ログを記録する。長押しで開くログ画面が `@Query` でリアルタイム表示する。
/// メッセージは表示時に言語追従できるよう、確定文ではなくローカライズ用フォーマットキー＋引数で保存する。
@MainActor
struct ArticleLogger {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func log(_ article: LearningArticle, _ key: String, _ args: [String] = [], isError: Bool = false) {
        guard !article.isDeleted else { return }
        let entry = ArticleLogEntry(messageKey: key, messageArgs: args, isError: isError, articleID: article.id)
        entry.article = article
        modelContext.insert(entry)
        try? modelContext.save()
    }
}
