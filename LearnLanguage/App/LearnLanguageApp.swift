import SwiftUI
import SwiftData

@main
struct LearnLanguageApp: App {
    /// アプリ全体で共有する SwiftData コンテナ。
    let modelContainer: ModelContainer
    /// 教材生成の直列キュー（一覧に即表示・順次処理）。
    @State private var queue: GenerationQueue
    /// 一般設定の iCloud 同期（UserDefaults ⇄ KVS のミラーリング）。
    @State private var settingsSync: SettingsCloudSync

    init() {
        let container = Self.makeModelContainer()
        modelContainer = container
        // App.init は起動時にメインスレッドで呼ばれるため assumeIsolated で安全に生成する。
        _queue = State(initialValue: MainActor.assumeIsolated {
            GenerationQueue(modelContext: container.mainContext)
        })
        _settingsSync = State(initialValue: MainActor.assumeIsolated {
            let sync = SettingsCloudSync()
            sync.start()
            return sync
        })
        // 同期対応前に保存された API キー類（端末ローカル属性のまま）を、同期可能な項目に書き直す。
        KeychainStore.migrateToSynchronizable(accounts: [
            KeychainStore.geminiAPIKeyAccount,
            KeychainStore.pollinationsAPIKeyAccount,
            KeychainStore.cloudflareAccountIDAccount,
            KeychainStore.cloudflareAPITokenAccount,
        ])
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(modelContainer)
        .environment(queue)
    }

    /// SwiftData コンテナを構築する。記事データは CloudKit（プライベート DB）で端末間同期する。
    /// CloudKit コンテナが使えない環境（未署名ビルド・iCloud 障害等）ではローカルのみに
    /// フォールバックし、それも失敗（マイグレーション等）ならストアを作り直して起動を優先する。
    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([
            LearningArticle.self,
            ArticleSegment.self,
            GlossaryTerm.self,
            ArticleLogEntry.self,
        ])

        // 1. CloudKit 同期付き（entitlements の iCloud コンテナを自動使用）。
        let cloud = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .automatic)
        if let container = try? ModelContainer(for: schema, configurations: [cloud]) {
            return container
        }

        // 2. ローカルのみ（既存データは保持したまま同期だけ諦める）。
        let localOnly = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
        if let container = try? ModelContainer(for: schema, configurations: [localOnly]) {
            return container
        }

        // 3. マイグレーション失敗等 → 既存ストアを削除して作り直す（履歴は失われるが起動を優先）。
        let storeURL = localOnly.url
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
        if let container = try? ModelContainer(for: schema, configurations: [localOnly]) {
            return container
        }
        let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: [memory])
    }
}
