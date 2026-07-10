import XCTest
import SwiftData
@testable import LearnLanguage

/// `GenerationQueue`（生成パイプラインの心臓部）の特性化テスト。
/// 挙動を固定して以降のリファクタリング（Phase 4/5 の分解）の回帰検出に使う。
@MainActor
final class GenerationQueueTests: XCTestCase {

    // MARK: - モック（テスト専用のスパイ。呼び出し回数を検証するため class + @unchecked Sendable）

    /// - Note: `GenerationQueue` は @MainActor で、スパイの可変状態も MainActor 上でのみ
    ///   読み書きされる（テストは全て @MainActor）。Sendable チェックは意図的に unchecked で回避する。
    final class ExtractorSpy: ContentExtracting, @unchecked Sendable {
        private(set) var callCount = 0
        var result: Result<ExtractedArticle, Error>
        init(result: Result<ExtractedArticle, Error>) { self.result = result }
        func extract(from url: URL) async throws -> ExtractedArticle {
            callCount += 1
            return try result.get()
        }
    }

    final class BatchRewriterSpy: BatchRewriting, @unchecked Sendable {
        private(set) var callCount = 0
        private(set) var lastItems: [RewriteBatchItem] = []
        var result: Result<[[RewrittenSegment]?], Error>
        init(result: Result<[[RewrittenSegment]?], Error>) { self.result = result }
        func rewriteBatch(_ items: [RewriteBatchItem], nativeLanguageCode: String) async throws -> [[RewrittenSegment]?] {
            callCount += 1
            lastItems = items
            return try result.get()
        }
    }

    final class OnDeviceRewriterSpy: TextRewriting, @unchecked Sendable {
        private(set) var callCount = 0
        var result: Result<[RewrittenSegment], Error>
        init(result: Result<[RewrittenSegment], Error>) { self.result = result }
        func rewrite(text: String, level: ReadingLevel, languageCode: String, nativeLanguageCode: String) async throws -> [RewrittenSegment] {
            callCount += 1
            return try result.get()
        }
    }

    /// イラスト生成のスパイ。`onCall` で副作用（記事削除の模擬など）を差し込める。
    final class IllustratorSpy: IllustrationGenerating, @unchecked Sendable {
        private(set) var callCount = 0
        var result: IllustrationResult = .success(Data([0x01]))
        var onCall: (() -> Void)?
        func illustrate(prompt: String) async -> IllustrationResult {
            callCount += 1
            onCall?()
            return result
        }
    }

    // MARK: - ヘルパー

    private func makeContext() throws -> ModelContext {
        let schema = Schema([LearningArticle.self, ArticleSegment.self, GlossaryTerm.self, ArticleLogEntry.self])
        // cloudKitDatabase の既定は .automatic で、アプリに iCloud entitlement があると
        // in-memory でも CloudKit ミラーリングを試みてしまう（アカウント無しの CI/Simulator で落ちる）
        // → テストでは明示的に .none。
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private func makeQueuedArticle(
        title: String = "Example",
        segments: [ArticleSegment] = [],
        ownerDeviceID: String = DeviceID.current
    ) -> LearningArticle {
        let article = LearningArticle(
            sourceURL: URL(string: "https://example.com/\(UUID().uuidString)")!,
            title: title,
            languageCode: "en",
            translationLanguageCode: "ja",
            targetLevel: ReadingLevel.beginner.storageValue
        )
        article.status = .queued
        article.ownerDeviceID = ownerDeviceID
        article.segments = segments
        for segment in segments { segment.article = article }
        return article
    }

    private func makeExtracted(text: String = "Some extracted body text.") -> ExtractedArticle {
        ExtractedArticle(title: "Extracted Title", text: text, languageCode: "en")
    }

    private func makeRewritten(count: Int = 2) -> [RewrittenSegment] {
        (0..<count).map { RewrittenSegment(order: $0, text: "Segment \($0)", advancedTerms: []) }
    }

    // MARK: - enqueue（同期的な帳簿処理）

    func testEnqueueSetsQueuedStatusAndLogsWithoutProcessing() throws {
        let context = try makeContext()
        // 実サービスへは絶対に到達しないダミー（呼ばれたら即座に失敗させて検出する）。
        let queue = GenerationQueue(
            modelContext: context,
            makeExtractor: { ExtractorSpy(result: .failure(URLError(.badURL))) },
            makeOnDeviceRewriter: { OnDeviceRewriterSpy(result: .failure(URLError(.badURL))) },
            makeBatchRewriter: { nil },
            makeIllustrator: { IllustratorSpy() }
        )

        queue.enqueue(url: URL(string: "https://example.com/a")!, level: .beginner, nativeLanguageCode: "ja")

        let articles = try context.fetch(FetchDescriptor<LearningArticle>())
        XCTAssertEqual(articles.count, 1)
        XCTAssertEqual(articles.first?.status, .queued)

        let logs = try context.fetch(FetchDescriptor<ArticleLogEntry>())
        XCTAssertEqual(logs.count, 1, "キュー追加で1件ログが記録される")
    }

    func testEnqueueTwicePlacesNewestFirst() throws {
        let context = try makeContext()
        let queue = GenerationQueue(
            modelContext: context,
            makeExtractor: { ExtractorSpy(result: .failure(URLError(.badURL))) },
            makeOnDeviceRewriter: { OnDeviceRewriterSpy(result: .failure(URLError(.badURL))) },
            makeBatchRewriter: { nil },
            makeIllustrator: { IllustratorSpy() }
        )

        queue.enqueue(url: URL(string: "https://example.com/first")!, level: .beginner, nativeLanguageCode: "ja")
        queue.enqueue(url: URL(string: "https://example.com/second")!, level: .beginner, nativeLanguageCode: "ja")

        let articles = try context.fetch(
            FetchDescriptor<LearningArticle>(sortBy: [SortDescriptor(\.sortIndex, order: .forward)])
        )
        XCTAssertEqual(articles.map(\.title.isEmpty), [false, false])
        XCTAssertEqual(articles.first?.sourceURL.absoluteString, "https://example.com/second",
                       "後から追加した記事が sortIndex 最小＝先頭に来る")
    }

    /// 処理開始ログに「どの端末が処理したか」が記録される（iCloud 同期先で
    /// 「他端末の進捗表示」と「この端末の実処理」を切り分けられるようにするため）。
    func testProcessingStartLogRecordsExecutingDeviceLabel() async throws {
        let context = try makeContext()
        let article = makeQueuedArticle()
        context.insert(article)
        try context.save()
        let queue = GenerationQueue(
            modelContext: context,
            makeExtractor: { ExtractorSpy(result: .success(self.makeExtracted())) },
            makeOnDeviceRewriter: { OnDeviceRewriterSpy(result: .success(self.makeRewritten())) },
            makeBatchRewriter: { nil },
            makeIllustrator: { IllustratorSpy() }
        )

        await queue.processIfNeeded()

        let logs = try context.fetch(FetchDescriptor<ArticleLogEntry>())
        let start = logs.first { $0.messageKey.hasPrefix("処理を開始しました") }
        XCTAssertNotNil(start, "処理開始ログが記録される")
        XCTAssertEqual(start?.messageArgs.first, DeviceID.displayLabel,
                       "処理開始ログに担当端末のラベルが入る")
        XCTAssertFalse(DeviceID.displayLabel.isEmpty)
    }

    // MARK: - 処理パイプライン（processIfNeeded を直接 await して決定的に検証）

    func testHappyPathReachesCompletedAndCallsEachServiceOnce() async throws {
        let context = try makeContext()
        let extractor = ExtractorSpy(result: .success(makeExtracted()))
        let batchRewriter = BatchRewriterSpy(result: .success([makeRewritten(count: 2)]))
        let illustrator = IllustratorSpy()

        let queue = GenerationQueue(
            modelContext: context,
            makeExtractor: { extractor },
            makeOnDeviceRewriter: { OnDeviceRewriterSpy(result: .failure(URLError(.badURL))) },
            makeBatchRewriter: { batchRewriter },
            makeIllustrator: { illustrator }
        )

        let article = makeQueuedArticle()
        context.insert(article)
        try context.save()

        await queue.processIfNeeded()

        XCTAssertEqual(article.status, .completed)
        XCTAssertEqual(article.segments.count, 2)
        XCTAssertTrue(article.segments.allSatisfy { $0.imageState == .ready })
        XCTAssertEqual(extractor.callCount, 1)
        XCTAssertEqual(batchRewriter.callCount, 1)
        XCTAssertEqual(illustrator.callCount, 2, "セグメント数ぶんイラスト生成が呼ばれる")
        XCTAssertEqual(batchRewriter.lastItems.first?.languageCode, article.languageCode,
                       "書き換えには記事の学習対象言語（抽出された元言語ではなく）を渡す")
    }

    func testExtractionFailureMarksFailedWithoutCallingRewriterOrIllustrator() async throws {
        let context = try makeContext()
        let extractor = ExtractorSpy(result: .failure(URLError(.notConnectedToInternet)))
        let batchRewriter = BatchRewriterSpy(result: .success([makeRewritten()]))
        let illustrator = IllustratorSpy()

        let queue = GenerationQueue(
            modelContext: context,
            makeExtractor: { extractor },
            makeOnDeviceRewriter: { OnDeviceRewriterSpy(result: .failure(URLError(.badURL))) },
            makeBatchRewriter: { batchRewriter },
            makeIllustrator: { illustrator }
        )

        let article = makeQueuedArticle()
        context.insert(article)
        try context.save()

        await queue.processIfNeeded()

        XCTAssertEqual(article.status, .failed)
        XCTAssertNotNil(article.failureReason)
        XCTAssertTrue(article.segments.isEmpty)
        XCTAssertEqual(extractor.callCount, 1)
        XCTAssertEqual(batchRewriter.callCount, 0, "抽出できなければ書き換えリクエストを送らない")
        XCTAssertEqual(illustrator.callCount, 0)
    }

    func testBatchRewriteThrowsMarksArticleFailedWithErrorReason() async throws {
        let context = try makeContext()
        let extractor = ExtractorSpy(result: .success(makeExtracted()))
        struct DummyError: LocalizedError { var errorDescription: String? { "quota exceeded" } }
        let batchRewriter = BatchRewriterSpy(result: .failure(DummyError()))

        let queue = GenerationQueue(
            modelContext: context,
            makeExtractor: { extractor },
            makeOnDeviceRewriter: { OnDeviceRewriterSpy(result: .failure(URLError(.badURL))) },
            makeBatchRewriter: { batchRewriter },
            makeIllustrator: { IllustratorSpy() }
        )

        let article = makeQueuedArticle()
        context.insert(article)
        try context.save()

        await queue.processIfNeeded()

        XCTAssertEqual(article.status, .failed)
        XCTAssertEqual(article.failureReason, "quota exceeded")
    }

    func testPartialBatchFailureIsolatesOnlyTheEmptyResultArticle() async throws {
        let context = try makeContext()
        let extractor = ExtractorSpy(result: .success(makeExtracted()))
        // 2記事バッチ: 1件目は書き換え成功、2件目は空配列（書き換え失敗相当）。
        let batchRewriter = BatchRewriterSpy(result: .success([makeRewritten(count: 1), nil]))

        let queue = GenerationQueue(
            modelContext: context,
            makeExtractor: { extractor },
            makeOnDeviceRewriter: { OnDeviceRewriterSpy(result: .failure(URLError(.badURL))) },
            makeBatchRewriter: { batchRewriter },
            makeIllustrator: { IllustratorSpy() }
        )

        let ok = makeQueuedArticle(title: "ok")
        let bad = makeQueuedArticle(title: "bad")
        context.insert(ok)
        context.insert(bad)
        try context.save()

        await queue.processIfNeeded()

        let oneSucceeded = (ok.status == .completed) != (bad.status == .completed)
        XCTAssertTrue(oneSucceeded, "一方が成功しもう一方だけが失敗する（バッチ内で互いに影響しない）")
    }

    func testOnDeviceFallbackIsUsedWhenNoBatchRewriter() async throws {
        let context = try makeContext()
        let extractor = ExtractorSpy(result: .success(makeExtracted()))
        let onDevice = OnDeviceRewriterSpy(result: .success(makeRewritten(count: 1)))

        let queue = GenerationQueue(
            modelContext: context,
            makeExtractor: { extractor },
            makeOnDeviceRewriter: { onDevice },
            makeBatchRewriter: { nil },
            makeIllustrator: { IllustratorSpy() }
        )

        let article = makeQueuedArticle()
        context.insert(article)
        try context.save()

        await queue.processIfNeeded()

        XCTAssertEqual(onDevice.callCount, 1)
        XCTAssertEqual(article.status, .completed)
    }

    // MARK: - 再開の冪等性（中断からの再開で API を再消費しない）

    func testResumeSkipsExtractionAndRewriteWhenSegmentsAlreadyExist() async throws {
        let context = try makeContext()
        let extractor = ExtractorSpy(result: .success(makeExtracted()))
        let batchRewriter = BatchRewriterSpy(result: .success([makeRewritten()]))
        let illustrator = IllustratorSpy()

        let queue = GenerationQueue(
            modelContext: context,
            makeExtractor: { extractor },
            makeOnDeviceRewriter: { OnDeviceRewriterSpy(result: .failure(URLError(.badURL))) },
            makeBatchRewriter: { batchRewriter },
            makeIllustrator: { illustrator }
        )

        // 中断からの再開を模す: 既にセグメントを持つ記事（1枚は生成済み、1枚は失敗のまま）。
        let readySegment = ArticleSegment(order: 0, rewrittenText: "done", imageData: Data([0x01]), imageState: .ready)
        let failedSegment = ArticleSegment(order: 1, rewrittenText: "retry me", imageState: .failed)
        let article = makeQueuedArticle(segments: [readySegment, failedSegment])
        context.insert(article)
        try context.save()

        await queue.processIfNeeded()

        XCTAssertEqual(extractor.callCount, 0, "本文が既にあるので再抽出しない")
        XCTAssertEqual(batchRewriter.callCount, 0, "本文が既にあるので再書き換えしない")
        XCTAssertEqual(illustrator.callCount, 1, "未完のイラストだけ再生成する")
        XCTAssertEqual(article.status, .completed)
        XCTAssertTrue(article.segments.allSatisfy { $0.imageState == .ready })
    }

    // MARK: - 端末オーナーシップ（iCloud 同期先で二重生成しない）

    func testOtherDevicesQueuedArticleIsNotProcessed() async throws {
        let context = try makeContext()
        let extractor = ExtractorSpy(result: .success(makeExtracted()))
        let queue = GenerationQueue(
            modelContext: context,
            makeExtractor: { extractor },
            makeOnDeviceRewriter: { OnDeviceRewriterSpy(result: .failure(URLError(.badURL))) },
            makeBatchRewriter: { BatchRewriterSpy(result: .success([self.makeRewritten()])) },
            makeIllustrator: { IllustratorSpy() }
        )

        // iCloud 同期で流れてきた「他端末がオーナーの待機中記事」を模す。
        let foreign = makeQueuedArticle(title: "from-iphone", ownerDeviceID: "other-device")
        context.insert(foreign)
        try context.save()

        await queue.processIfNeeded()

        XCTAssertEqual(extractor.callCount, 0, "他端末の記事はこの端末で処理しない")
        XCTAssertEqual(foreign.status, .queued, "ステータスも触らない（オーナー端末が処理する）")
    }

    func testResumePendingSkipsOtherDevicesProcessingArticle() async throws {
        let context = try makeContext()
        let extractor = ExtractorSpy(result: .success(makeExtracted()))
        let queue = GenerationQueue(
            modelContext: context,
            makeExtractor: { extractor },
            makeOnDeviceRewriter: { OnDeviceRewriterSpy(result: .failure(URLError(.badURL))) },
            makeBatchRewriter: { BatchRewriterSpy(result: .success([self.makeRewritten()])) },
            makeIllustrator: { IllustratorSpy() }
        )

        // 他端末で処理中（同期で見えているだけ）の記事。
        let foreign = makeQueuedArticle(title: "processing-on-iphone", ownerDeviceID: "other-device")
        foreign.status = .processing
        context.insert(foreign)
        try context.save()

        queue.resumePending()
        await queue.processIfNeeded()

        XCTAssertEqual(foreign.status, .processing, "他端末の処理中記事を requeue で横取りしない")
        XCTAssertEqual(extractor.callCount, 0)
    }

    func testRetryClaimsOwnershipAndProcesses() async throws {
        let context = try makeContext()
        let extractor = ExtractorSpy(result: .success(makeExtracted()))
        let queue = GenerationQueue(
            modelContext: context,
            makeExtractor: { extractor },
            makeOnDeviceRewriter: { OnDeviceRewriterSpy(result: .failure(URLError(.badURL))) },
            makeBatchRewriter: { BatchRewriterSpy(result: .success([self.makeRewritten()])) },
            makeIllustrator: { IllustratorSpy() }
        )

        // 他端末で失敗した記事を、この端末で引き取って再実行する。
        let foreign = makeQueuedArticle(title: "failed-elsewhere", ownerDeviceID: "other-device")
        foreign.status = .failed
        context.insert(foreign)
        try context.save()

        queue.retry(foreign)
        await queue.processIfNeeded()

        XCTAssertEqual(foreign.ownerDeviceID, DeviceID.current, "再実行した端末が新しいオーナーになる")
        XCTAssertEqual(foreign.status, .completed)
        XCTAssertEqual(extractor.callCount, 1)
    }

    // MARK: - 再生成（学習対象言語の変更）

    func testRegenerateClearsSegmentsAndRebuildsInNewLanguage() async throws {
        let context = try makeContext()
        let extractor = ExtractorSpy(result: .success(makeExtracted()))
        let batchRewriter = BatchRewriterSpy(result: .success([makeRewritten(count: 2)]))
        let queue = GenerationQueue(
            modelContext: context,
            makeExtractor: { extractor },
            makeOnDeviceRewriter: { OnDeviceRewriterSpy(result: .failure(URLError(.badURL))) },
            makeBatchRewriter: { batchRewriter },
            makeIllustrator: { IllustratorSpy() }
        )

        // 完成済みの英語教材（セグメントあり）。
        let done = ArticleSegment(order: 0, rewrittenText: "old english", imageData: Data([0x01]), imageState: .ready)
        let article = makeQueuedArticle(segments: [done])
        article.status = .completed
        context.insert(article)
        try context.save()

        queue.regenerate(article, targetLanguageCode: "fr")
        await queue.processIfNeeded()

        XCTAssertEqual(article.languageCode, "fr", "学習対象言語が更新される")
        XCTAssertEqual(extractor.callCount, 1, "セグメントを破棄したので再抽出される（冪等スキップに掛からない）")
        XCTAssertEqual(batchRewriter.lastItems.first?.languageCode, "fr", "新しい言語で書き換えを依頼する")
        XCTAssertEqual(article.status, .completed)
        XCTAssertEqual(article.segments.count, 2)
        XCTAssertFalse(article.segments.contains { $0.rewrittenText == "old english" }, "旧セグメントは残らない")
    }

    // MARK: - 削除された記事の安全な中断

    /// バッチ取得（`nextQueuedBatch`）は SwiftData の #Predicate で `status == .queued` のみを
    /// フェッチするため、削除済みの記事はそもそも処理対象に含まれない。
    ///
    /// - Note: `ModelContext.delete()` 直後は `isDeleted == true` だが、その後 `save()` すると
    ///   `isDeleted` は `false` に戻る（実測済み）。`processBatch`/`illustrateSegments` 内の
    ///   `!article.isDeleted` ガードは頻繁な中間 save の後では検知できない可能性があり、
    ///   「処理の最中に削除された」場合の安全性は本テストでは保証できない
    ///   （Phase 1 以降で要調査。docs/REFACTORING_PLAN.md に追記）。
    func testDeletedArticleIsNeverFetchedIntoQueue() async throws {
        let context = try makeContext()
        let extractor = ExtractorSpy(result: .success(makeExtracted()))
        let batchRewriter = BatchRewriterSpy(result: .success([makeRewritten()]))
        let illustrator = IllustratorSpy()

        let queue = GenerationQueue(
            modelContext: context,
            makeExtractor: { extractor },
            makeOnDeviceRewriter: { OnDeviceRewriterSpy(result: .failure(URLError(.badURL))) },
            makeBatchRewriter: { batchRewriter },
            makeIllustrator: { illustrator }
        )

        let deleted = makeQueuedArticle(title: "deleted-before-processing")
        let survivor = makeQueuedArticle(title: "survivor")
        context.insert(deleted)
        context.insert(survivor)
        try context.save()

        context.delete(deleted)
        try context.save()

        await queue.processIfNeeded()

        XCTAssertEqual(extractor.callCount, 1, "削除済みの記事ぶんは呼ばれない")
        XCTAssertEqual(survivor.status, .completed)
    }
}
