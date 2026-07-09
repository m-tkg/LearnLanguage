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
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private func makeQueuedArticle(
        title: String = "Example",
        segments: [ArticleSegment] = []
    ) -> LearningArticle {
        let article = LearningArticle(
            sourceURL: URL(string: "https://example.com/\(UUID().uuidString)")!,
            title: title,
            languageCode: "en",
            translationLanguageCode: "ja",
            targetLevel: ReadingLevel.beginner.storageValue
        )
        article.status = .queued
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
