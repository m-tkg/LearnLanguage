import Foundation
import SwiftData

/// プレビュー/テスト用のサンプル記事を組み立てるファクトリ。
enum SampleData {
    /// セグメントと用語集を持つ 1 本の記事。
    static func makeArticle(title: String = "The Curious Octopus") -> LearningArticle {
        let article = LearningArticle(
            sourceURL: URL(string: "https://example.com/octopus")!,
            title: title,
            languageCode: "en",
            translationLanguageCode: "ja",
            targetLevel: 3,
            originalText: "Octopuses are remarkable animals.",
            isFavorite: false
        )
        let seg0 = ArticleSegment(
            order: 0,
            rewrittenText: "Octopuses are remarkable animals. They can change color to hide.",
            imageState: .ready,
            glossary: [GlossaryTerm(surface: "remarkable", translation: "驚くべき")]
        )
        let seg1 = ArticleSegment(
            order: 1,
            rewrittenText: "They are also very smart and can solve puzzles.",
            imageState: .pending
        )
        article.segments = [seg0, seg1]
        return article
    }

    /// メモリ内コンテナにサンプルを投入して返す（プレビュー用）。
    @MainActor
    static func previewContainer() -> ModelContainer {
        // cloudKitDatabase 既定 .automatic の巻き込みを避け、プレビューは常にローカルのみ。
        let container = try! ModelContainer(
            for: LearningArticle.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        container.mainContext.insert(makeArticle())
        container.mainContext.insert(makeArticle(title: "A Day at the Market"))
        return container
    }
}
