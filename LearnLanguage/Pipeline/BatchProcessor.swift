import Foundation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif
import os

/// キューの 1 バッチ（本文抽出 → 書き換え → イラスト生成）の実処理。`GenerationQueue` から
/// ports（抽出/書き換え/イラスト生成の実サービス取得）とロガーを注入されて動く
/// （テストではモックを注入し、呼び出し回数や再開の冪等性を検証できる）。
@MainActor
struct BatchProcessor {
    private static let logger = Logger(subsystem: "com.mtkg.LearnLanguage", category: "Queue")

    private let modelContext: ModelContext
    private let articleLogger: ArticleLogger
    private let makeExtractor: () -> any ContentExtracting
    private let makeOnDeviceRewriter: () -> any TextRewriting
    private let makeBatchRewriter: () -> (any BatchRewriting)?
    private let makeIllustrator: () -> any IllustrationGenerating

    init(
        modelContext: ModelContext,
        articleLogger: ArticleLogger,
        makeExtractor: @escaping () -> any ContentExtracting,
        makeOnDeviceRewriter: @escaping () -> any TextRewriting,
        makeBatchRewriter: @escaping () -> (any BatchRewriting)?,
        makeIllustrator: @escaping () -> any IllustrationGenerating
    ) {
        self.modelContext = modelContext
        self.articleLogger = articleLogger
        self.makeExtractor = makeExtractor
        self.makeOnDeviceRewriter = makeOnDeviceRewriter
        self.makeBatchRewriter = makeBatchRewriter
        self.makeIllustrator = makeIllustrator
    }

    private func log(_ article: LearningArticle, _ key: String, _ args: [String] = [], isError: Bool = false) {
        articleLogger.log(article, key, args, isError: isError)
    }

    func process(_ batch: [LearningArticle]) async {
        for article in batch {
            article.status = .processing
            article.failureReason = nil
            log(article, "処理を開始しました。")
        }
        try? modelContext.save()

        // バックグラウンドに回っても ~30 秒は継続できるよう保険をかける（iOS のみ。
        // macOS はウィンドウが背面でもプロセスが動き続けるため不要）。
        #if canImport(UIKit)
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "GenerateBatch")
        defer { if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID) } }
        #endif

        let native = batch.first?.translationLanguageCode ?? "ja"
        let levels = batch.map { ReadingLevel(storageValue: $0.targetLevel, isOriginal: $0.isOriginal) }

        // Phase 0: 本文抽出（端末側）。取れた記事は一覧からすぐ入れるよう、この後に本文を反映する。
        let extractor = makeExtractor()
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
        if let batchRewriter = makeBatchRewriter() {
            var itemIndices: [Int] = []
            var items: [RewriteBatchItem] = []
            for index in 0..<batch.count {
                if let ex = extracted[index] {
                    // languageCode は学習対象（出力）言語。元記事が別言語なら書き換え時に翻訳される。
                    items.append(RewriteBatchItem(text: ex.text, level: levels[index], languageCode: batch[index].languageCode))
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
            let rewriter = makeOnDeviceRewriter()
            for index in 0..<batch.count {
                guard let ex = extracted[index], !batch[index].isDeleted else { continue }
                log(batch[index], "本文をレベル別に書き換えています…（オンデバイス）")
                segmentsPerArticle[index] = try? await rewriter.rewrite(
                    text: ex.text, level: levels[index],
                    languageCode: batch[index].languageCode, nativeLanguageCode: native
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
            // languageCode は enqueue 時に選択された学習対象言語のまま維持する
            // （抽出された元記事の言語で上書きしない。教材・読み上げは対象言語）。
            article.originalText = ex.text
            setSegments(article, from: segments)
            log(article, "本文が準備できました（タイトル: %@）。ここから学習画面に入れます。", [ex.title])
        }
        try? modelContext.save()

        // Phase 2: 各記事のイラスト生成（逐次保存で一覧/学習画面が随時更新される）。
        let illustrator = makeIllustrator()
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
