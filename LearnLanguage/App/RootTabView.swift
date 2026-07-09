import SwiftUI

/// アプリのルート。記事 / 設定 の 2 タブ構成。
/// 記事の追加は「記事」タブ右上の＋から、またはシェアシート経由（起動/前面化時に受信箱を取り込む）。
struct RootTabView: View {
    @Environment(GenerationQueue.self) private var queue
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("nativeLanguageCode") private var nativeLanguageCode = "ja"

    var body: some View {
        TabView {
            HistoryView()
                .tabItem {
                    Label("記事", systemImage: "doc.text")
                }

            SettingsView()
                .tabItem {
                    Label("設定", systemImage: "gearshape")
                }
        }
        .task {
            queue.resumePending()
            importSharedURLs()
        }
        .onChange(of: scenePhase) { _, phase in
            // 他アプリからシェアされた URL は、前面に戻ったタイミングで取り込む。
            if phase == .active { importSharedURLs() }
        }
    }

    /// シェアシート経由で受信箱に貯まった共有を、選択された難易度でキューに追加する。
    private func importSharedURLs() {
        for share in SharedInbox.drain() {
            guard let url = URL(string: share.url) else { continue }
            let level = ReadingLevel(storageValue: share.levelStorageValue,
                                     isOriginal: share.levelStorageValue <= 0)
            queue.enqueue(url: url, level: level, nativeLanguageCode: nativeLanguageCode)
        }
    }
}
