import Foundation

/// Port のモック実装群。実機（Apple Intelligence 対応端末）が無くても
/// UI・永続化・パイプラインを開発/プレビュー/テストできるようにする。

/// 抽出済み本文をそのまま返すモック。
struct MockContentExtractor: ContentExtracting {
    var result: ExtractedArticle

    init(result: ExtractedArticle = .init(
        title: "The Curious Octopus",
        text: "Octopuses are remarkable animals. They can change color to hide. "
            + "They are also very intelligent and can solve puzzles. "
            + "Scientists study them to understand how their minds work.",
        languageCode: "en"
    )) {
        self.result = result
    }

    func extract(from url: URL) async throws -> ExtractedArticle {
        result
    }
}

/// 文単位に素朴分割し、書き換えは行わないモック（レベル制御の代わりに固定用語集を付与）。
struct MockTextRewriter: TextRewriting {
    var segmentCount: Int = 3

    func rewrite(
        text: String,
        level: ReadingLevel,
        languageCode: String,
        nativeLanguageCode: String
    ) async throws -> [RewrittenSegment] {
        let sentences = text
            .split(whereSeparator: { $0 == "." })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !sentences.isEmpty else { return [] }

        let chunks = Self.chunk(sentences, into: max(1, segmentCount))
        return chunks.enumerated().map { index, group in
            RewrittenSegment(
                order: index,
                text: group.joined(separator: ". ") + ".",
                advancedTerms: index == 0
                    ? [AdvancedTerm(surface: "remarkable", translation: "驚くべき")]
                    : []
            )
        }
    }

    private static func chunk(_ items: [String], into count: Int) -> [[String]] {
        guard count > 0 else { return [items] }
        var buckets: [[String]] = Array(repeating: [], count: count)
        for (i, item) in items.enumerated() {
            buckets[i % count].append(item)
        }
        return buckets.filter { !$0.isEmpty }
    }
}

/// 固定結果を返すイラストモック（既定は失敗＝プレースホルダ確認用）。
struct MockIllustrator: IllustrationGenerating {
    var result: IllustrationResult = .failure(reason: "モック: 画像なし")
    func illustrate(prompt: String) async -> IllustrationResult { result }
}

/// 何もしない読み上げモック。
@MainActor
final class MockSpeaker: Speaking {
    func speak(_ text: String, languageCode: String, rate: Float) {}
    func stop() {}
}

/// 可用性を固定で返すスタブ。
struct StubAvailabilityProvider: IntelligenceAvailabilityProviding {
    var value: IntelligenceAvailability = .init(llm: .available)
    func current() async -> IntelligenceAvailability { value }
}
