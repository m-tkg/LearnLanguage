import SwiftUI
import SwiftData

@main
struct LearnLanguageApp: App {
    /// アプリ全体で共有する SwiftData コンテナ。
    let modelContainer: ModelContainer
    /// 教材生成の直列キュー（一覧に即表示・順次処理）。
    @State private var queue: GenerationQueue

    init() {
        let container = Self.makeModelContainer()
        modelContainer = container
        // App.init は起動時にメインスレッドで呼ばれるため assumeIsolated で安全に生成する。
        _queue = State(initialValue: MainActor.assumeIsolated {
            GenerationQueue(modelContext: container.mainContext)
        })
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(modelContainer)
        .environment(queue)
    }

    /// SwiftData コンテナを構築する。マイグレーション失敗時はストアを作り直して起動を優先する。
    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([
            LearningArticle.self,
            ArticleSegment.self,
            GlossaryTerm.self,
            ArticleLogEntry.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        if let container = try? ModelContainer(for: schema, configurations: [configuration]) {
            return container
        }
        // マイグレーション失敗等 → 既存ストアを削除して作り直す（履歴は失われるが起動を優先）。
        let storeURL = configuration.url
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
        if let container = try? ModelContainer(for: schema, configurations: [configuration]) {
            return container
        }
        let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: [memory])
    }
}
