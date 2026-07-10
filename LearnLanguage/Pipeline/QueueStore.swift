import Foundation
import SwiftData

/// キューの状態問い合わせ・遷移に関する SwiftData クエリを一元化する。
/// ステータスは `ArticleStatus.rawValue` から都度取り出し、`#Predicate` 内でのマジック文字列の
/// 二重管理（enum の定義とクエリ文字列が食い違う事故）を避ける。
@MainActor
struct QueueStore {
    private let modelContext: ModelContext
    /// 1リクエストにまとめる最大件数（レート上限対策）。
    private static let batchSize = 5

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// 待機中の記事を古い順に最大 `batchSize` 件取得する。
    /// **この端末がオーナーの記事のみ**（iCloud 同期で流れてきた他端末の待機中記事は処理しない）。
    func nextQueuedBatch() -> [LearningArticle] {
        let queued = ArticleStatus.queued.rawValue
        let mine = DeviceID.current
        var descriptor = FetchDescriptor<LearningArticle>(
            predicate: #Predicate { $0.statusRaw == queued && $0.ownerDeviceID == mine },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        descriptor.fetchLimit = Self.batchSize
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// 現在の記事の最小 sortIndex（無ければ 0）。新規記事を一覧の先頭に出すために使う。
    func currentMinSortIndex() -> Int {
        var descriptor = FetchDescriptor<LearningArticle>(
            sortBy: [SortDescriptor(\.sortIndex, order: .forward)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first?.sortIndex ?? 0
    }

    /// 指定ステータスの記事を queued に戻す（起動時の再開など）。呼び出し側がキュー処理の再開を担う。
    /// **この端末がオーナーの記事のみ**（他端末で処理中の記事を横取りして再開しない）。
    func requeue(statuses: [ArticleStatus]) {
        let raws = statuses.map(\.rawValue)
        let mine = DeviceID.current
        let targets = (try? modelContext.fetch(
            FetchDescriptor<LearningArticle>(
                predicate: #Predicate { raws.contains($0.statusRaw) && $0.ownerDeviceID == mine }
            )
        )) ?? []
        for article in targets { article.status = .queued }
        if !targets.isEmpty { try? modelContext.save() }
    }
}
