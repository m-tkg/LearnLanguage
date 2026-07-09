import Foundation
import SwiftData
import UIKit
import os

/// 教材生成のキュー。押した時点でプレースホルダ記事を保存して一覧に表示し、
/// 1件ずつ順次処理する（前が終わったら次）。アプリがバックグラウンドに回っても
/// 30秒程度は処理を継続する（beginBackgroundTask）。状態は SwiftData に保存し、UI は @Query で観測。
@MainActor
@Observable
final class GenerationQueue {
    private static let logger = Logger(subsystem: "com.mtkg.LearnLanguage", category: "Queue")

    private let modelContext: ModelContext
    private var isProcessing = false
    /// 1リクエストにまとめる最大件数（レート上限対策）。
    private static let batchSize = 5

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// 生成をキューに追加。プレースホルダ記事を即保存して一覧に出し、順次処理を回す。
    func enqueue(url: URL, level: ReadingLevel, nativeLanguageCode: String) {
        let article = LearningArticle(
            sourceURL: url,
            title: url.host() ?? "記事",
            languageCode: "en",
            translationLanguageCode: nativeLanguageCode,
            targetLevel: level.storageValue,
            isOriginal: level == .original,
            originalText: ""
        )
        article.status = .queued
        // 一覧の先頭に出すため、現在の最小 sortIndex より小さい値を割り当てる。
        article.sortIndex = currentMinSortIndex() - 1
        modelContext.insert(article)
        log(article, "キューに追加しました（レベル: %@）。",
            [String(localized: String.LocalizationValue(level.displayName))])
        try? modelContext.save()
        Task { await processIfNeeded() }
    }

    /// 現在の記事の最小 sortIndex（無ければ 0）。
    private func currentMinSortIndex() -> Int {
        var descriptor = FetchDescriptor<LearningArticle>(
            sortBy: [SortDescriptor(\.sortIndex, order: .forward)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first?.sortIndex ?? 0
    }

    /// 記事に処理ログを 1 行追加する。長押しで開くログ画面が `@Query` でリアルタイム表示する。
    /// メッセージは表示時に言語追従できるよう、ローカライズ用フォーマットキー＋引数で保存する。
    private func log(_ article: LearningArticle, _ key: String, _ args: [String] = [], isError: Bool = false) {
        guard !article.isDeleted else { return }
        let entry = ArticleLogEntry(messageKey: key, messageArgs: args, isError: isError, articleID: article.id)
        entry.article = article
        modelContext.insert(entry)
        try? modelContext.save()
    }

    /// 中断された処理（processing のまま止まったもの）を再開しキューを回す（起動時）。
    func resumePending() {
        requeue(statuses: ["processing"])
    }

    /// 失敗・中断した記事を再試行する（Pull to refresh）。
    func retryIncomplete() {
        requeue(statuses: ["processing", "failed"])
    }

    /// 指定した記事だけを再実行する（一覧の長押し → 「再実行」）。
    func retry(_ article: LearningArticle) {
        guard !article.isDeleted else { return }
        article.status = .queued
        article.failureReason = nil
        log(article, "再実行します。")
        try? modelContext.save()
        Task { await processIfNeeded() }
    }

    private func requeue(statuses: [String]) {
        let targets = (try? modelContext.fetch(
            FetchDescriptor<LearningArticle>(predicate: #Predicate { statuses.contains($0.statusRaw) })
        )) ?? []
        for article in targets { article.status = .queued }
        if !targets.isEmpty { try? modelContext.save() }
        Task { await processIfNeeded() }
    }

    // MARK: - 処理ループ（直列）

    private func processIfNeeded() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        while true {
            let batch = nextQueuedBatch()
            if batch.isEmpty { break }
            await processBatch(batch)
        }
    }

    /// 待機中の記事を古い順に最大 `batchSize` 件取得する。
    private func nextQueuedBatch() -> [LearningArticle] {
        var descriptor = FetchDescriptor<LearningArticle>(
            predicate: #Predicate { $0.statusRaw == "queued" },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        descriptor.fetchLimit = Self.batchSize
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func processBatch(_ batch: [LearningArticle]) async {
        for article in batch {
            article.status = .processing
            article.failureReason = nil
            log(article, "処理を開始しました。")
        }
        try? modelContext.save()

        // バックグラウンドに回っても ~30 秒は継続できるよう保険をかける。
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "GenerateBatch")
        defer { if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID) } }

        let native = batch.first?.translationLanguageCode ?? "ja"
        let levels = batch.map { ReadingLevel(storageValue: $0.targetLevel, isOriginal: $0.isOriginal) }

        // Phase 0: 本文抽出（端末側）。取れた記事は一覧からすぐ入れるよう、この後に本文を反映する。
        let extractor = ArticleContentExtractor()
        var extracted = [ExtractedArticle?](repeating: nil, count: batch.count)
        for index in 0..<batch.count where !batch[index].isDeleted {
            // 既に書き換え済み（セグメントあり）の記事は中断からの再開 → 再抽出・再書き換えせず、イラストの続きから。
            if !batch[index].segments.isEmpty {
                log(batch[index], "本文・書き換えは完了済みです。イラストの続きから再開します。")
                continue
            }
            log(batch[index], "本文を取得しています…（%@）", [batch[index].sourceURL.host() ?? ""])
            extracted[index] = try? await extractor.extract(from: batch[index].sourceURL)
            if let ex = extracted[index] {
                log(batch[index], "本文を取得しました（%@ 文字・言語: %@）。",
                    [String(ex.text.count), ex.languageCode ?? "?"])
            } else {
                log(batch[index], "本文を取得できませんでした。", isError: true)
            }
        }

        // Phase 1: 書き換え。Gemini 選択時は複数記事を1リクエストにまとめる（JSON モードで安定）。
        var segmentsPerArticle = [[RewrittenSegment]?](repeating: nil, count: batch.count)
        if let batchRewriter = RewriterFactory.liveBatchRewriter() {
            var itemIndices: [Int] = []
            var items: [RewriteBatchItem] = []
            for index in 0..<batch.count {
                if let ex = extracted[index] {
                    items.append(RewriteBatchItem(text: ex.text, level: levels[index], languageCode: ex.languageCode ?? "en"))
                    itemIndices.append(index)
                }
            }
            if !items.isEmpty {
                for index in itemIndices {
                    log(batch[index], "本文をレベル別に書き換えています…（Gemini: %@）", [GeminiModel.current])
                }
                do {
                    let results = try await batchRewriter.rewriteBatch(items, nativeLanguageCode: native)
                    for (position, articleIndex) in itemIndices.enumerated() where position < results.count {
                        segmentsPerArticle[articleIndex] = results[position]
                        if let segments = results[position], !segments.isEmpty {
                            log(batch[articleIndex], "書き換えが完了しました（%@ 分割）。", [String(segments.count)])
                        } else {
                            log(batch[articleIndex], "書き換え結果が空でした。", isError: true)
                        }
                    }
                } catch {
                    Self.logger.error("batch rewrite failed: \(String(describing: error), privacy: .public)")
                    for index in itemIndices where !batch[index].isDeleted {
                        batch[index].status = .failed
                        batch[index].failureReason = error.localizedDescription
                        log(batch[index], "書き換えに失敗しました: %@", [error.localizedDescription], isError: true)
                    }
                }
            }
        } else {
            // オンデバイス（Apple）で個別に書き換え。
            let rewriter = RewriterFactory.live()
            for index in 0..<batch.count {
                guard let ex = extracted[index], !batch[index].isDeleted else { continue }
                log(batch[index], "本文をレベル別に書き換えています…（オンデバイス）")
                segmentsPerArticle[index] = try? await rewriter.rewrite(
                    text: ex.text, level: levels[index],
                    languageCode: ex.languageCode ?? "en", nativeLanguageCode: native
                )
                if let segments = segmentsPerArticle[index], !segments.isEmpty {
                    log(batch[index], "書き換えが完了しました（%@ 分割）。", [String(segments.count)])
                } else {
                    log(batch[index], "書き換えに失敗しました。", isError: true)
                }
            }
        }

        // 本文（セグメント）を反映。ここで各記事が「一覧から入れる」状態になる。
        for (index, article) in batch.enumerated() {
            guard !article.isDeleted, article.status == .processing else { continue }
            // 再開時: 既にセグメントがある記事は反映済み → イラスト工程へそのまま進む。
            if !article.segments.isEmpty { continue }
            guard let ex = extracted[index] else {
                article.status = .failed
                article.failureReason = "本文を取得できませんでした。"
                continue
            }
            guard let segments = segmentsPerArticle[index], !segments.isEmpty else {
                article.status = .failed
                article.failureReason = article.failureReason ?? "書き換えに失敗しました。"
                continue
            }
            article.title = ex.title
            article.languageCode = ex.languageCode ?? "en"
            article.originalText = ex.text
            setSegments(article, from: segments)
            log(article, "本文が準備できました（タイトル: %@）。ここから学習画面に入れます。", [ex.title])
        }
        try? modelContext.save()

        // Phase 2: 各記事のイラスト生成（逐次保存で一覧/学習画面が随時更新される）。
        let illustrator = IllustratorFactory.live()
        for article in batch {
            guard !article.isDeleted, article.status == .processing, !article.segments.isEmpty else { continue }
            await illustrateSegments(of: article, using: illustrator)
            guard !article.isDeleted else { continue }
            article.status = .completed
            log(article, "すべての処理が完了しました。")
            try? modelContext.save()
        }
    }

    /// 書き換え結果を記事のセグメントに反映（擬似タグは除去）。
    private func setSegments(_ article: LearningArticle, from rewritten: [RewrittenSegment]) {
        let segments = rewritten.map { $0.sanitized() }.map { r -> ArticleSegment in
            let segment = ArticleSegment(
                order: r.order,
                rewrittenText: r.text,
                imagePrompt: r.imagePrompt.isEmpty ? nil : r.imagePrompt,
                imageState: .pending,
                glossary: r.advancedTerms.map { GlossaryTerm(surface: $0.surface, translation: $0.translation) }
            )
            segment.article = article
            return segment
        }
        article.segments = segments
    }

    /// 各セグメントのイラストをベストエフォートで生成する。
    private func illustrateSegments(of article: LearningArticle, using illustrator: any IllustrationGenerating) async {
        let sorted = article.segments.sorted(by: { $0.order < $1.order })
        let total = sorted.count
        for (position, segment) in sorted.enumerated() {
            guard !article.isDeleted else { return }
            // 再開時: 既に生成済みのイラストは作り直さない（無料枠の再消費を避ける）。
            if segment.imageState == .ready, segment.imageData != nil { continue }
            segment.imageState = .generating
            log(article, "イラストを生成しています…（%@/%@）", [String(position + 1), String(total)])
            try? modelContext.save()
            let prompt = IllustrationPrompt.resolve(
                imagePrompt: segment.imagePrompt, fallbackText: segment.rewrittenText
            )
            switch await illustrator.illustrate(prompt: prompt) {
            case .success(let data):
                segment.imageData = data
                segment.imageFailureReason = nil
                segment.imageState = .ready
                log(article, "イラストが完成しました（%@/%@）。", [String(position + 1), String(total)])
            case .failure(let reason):
                segment.imageFailureReason = reason
                segment.imageState = .failed
                log(article, "イラストの生成に失敗しました（%@/%@）: %@",
                    [String(position + 1), String(total), reason], isError: true)
            }
            try? modelContext.save()
        }
    }

}
