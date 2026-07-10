import Foundation
import SwiftData

/// 教材生成のキュー。押した時点でプレースホルダ記事を保存して一覧に表示し、
/// 1件ずつ順次処理する（前が終わったら次）。状態は SwiftData に保存し、UI は @Query で観測。
/// SwiftData クエリは `QueueStore`、ログ記録は `ArticleLogger`、1バッチの実処理は
/// `BatchProcessor` に委譲し、ここではキューの直列処理ループと公開 API のみを持つ。
@MainActor
@Observable
final class GenerationQueue {
    private let modelContext: ModelContext
    private var isProcessing = false

    private let store: QueueStore
    private let articleLogger: ArticleLogger
    private let batchProcessor: BatchProcessor

    /// 抽出/書き換え/イラスト生成の実サービス取得。既定は本番実装（Factory 経由）、
    /// テストではモックを注入できる（アプリ側の呼び出しは変更不要）。
    init(
        modelContext: ModelContext,
        makeExtractor: @escaping () -> any ContentExtracting = { ArticleContentExtractor() },
        makeOnDeviceRewriter: @escaping () -> any TextRewriting = { RewriterFactory.live() },
        makeBatchRewriter: @escaping () -> (any BatchRewriting)? = { RewriterFactory.liveBatchRewriter() },
        makeIllustrator: @escaping () -> any IllustrationGenerating = { IllustratorFactory.live() }
    ) {
        self.modelContext = modelContext
        self.store = QueueStore(modelContext: modelContext)
        self.articleLogger = ArticleLogger(modelContext: modelContext)
        self.batchProcessor = BatchProcessor(
            modelContext: modelContext,
            articleLogger: articleLogger,
            makeExtractor: makeExtractor,
            makeOnDeviceRewriter: makeOnDeviceRewriter,
            makeBatchRewriter: makeBatchRewriter,
            makeIllustrator: makeIllustrator
        )
    }

    /// 生成をキューに追加。プレースホルダ記事を即保存して一覧に出し、順次処理を回す。
    /// - Parameter targetLanguageCode: 学習対象言語（教材の出力言語。元記事が別言語なら翻訳される）。
    func enqueue(url: URL, level: ReadingLevel, targetLanguageCode: String = "en", nativeLanguageCode: String) {
        let article = LearningArticle(
            sourceURL: url,
            title: url.host() ?? "記事",
            languageCode: targetLanguageCode,
            translationLanguageCode: nativeLanguageCode,
            targetLevel: level.storageValue,
            isOriginal: level == .original,
            originalText: ""
        )
        article.status = .queued
        // 一覧の先頭に出すため、現在の最小 sortIndex より小さい値を割り当てる。
        article.sortIndex = store.currentMinSortIndex() - 1
        modelContext.insert(article)
        articleLogger.log(article, "キューに追加しました（レベル: %@）。",
            [String(localized: String.LocalizationValue(level.displayName))])
        try? modelContext.save()
        Task { await processIfNeeded() }
    }

    /// 中断された処理（processing のまま止まったもの）を再開しキューを回す（起動時）。
    func resumePending() {
        store.requeue(statuses: [.processing])
        Task { await processIfNeeded() }
    }

    /// 指定した記事だけを再実行する（一覧の長押し → 「再実行」）。
    func retry(_ article: LearningArticle) {
        guard !article.isDeleted else { return }
        article.status = .queued
        article.failureReason = nil
        articleLogger.log(article, "再実行します。")
        try? modelContext.save()
        Task { await processIfNeeded() }
    }

    // MARK: - 処理ループ（直列）

    /// キューを直列で処理する。`enqueue`/`retry`/`resumePending` は `Task { await processIfNeeded() }`
    /// で fire-and-forget するが、テストはこれを直接 await して決定的に完了を待つ。
    func processIfNeeded() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        while true {
            let batch = store.nextQueuedBatch()
            if batch.isEmpty { break }
            await batchProcessor.process(batch)
        }
    }
}
