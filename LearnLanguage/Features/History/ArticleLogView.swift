import SwiftUI
import SwiftData

/// 記事の生成処理ログを時系列でリアルタイム表示する画面。一覧の長押しで開く。
/// `@Query` が同一 ModelContext の保存を自動反映するため、処理中はログが自動で伸びていく。
struct ArticleLogView: View {
    let article: LearningArticle
    @Environment(\.dismiss) private var dismiss

    @Query private var logs: [ArticleLogEntry]

    init(article: LearningArticle) {
        self.article = article
        let id = article.id
        _logs = Query(
            filter: #Predicate<ArticleLogEntry> { $0.articleID == id },
            sort: \.timestamp,
            order: .forward
        )
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        NavigationStack {
            Group {
                if logs.isEmpty {
                    ContentUnavailableView(
                        "ログはまだありません",
                        systemImage: "text.alignleft",
                        description: Text("処理が進むとここに記録されます。")
                    )
                } else {
                    ScrollViewReader { proxy in
                        List {
                            Section {
                                ForEach(logs) { entry in
                                    row(for: entry).id(entry.id)
                                }
                            } header: {
                                statusHeader
                            }
                        }
                        .onChange(of: logs.count) { _, _ in
                            if let last = logs.last {
                                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                        .onAppear {
                            if let last = logs.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .navigationTitle("処理ログ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    /// 現在の状態を示すヘッダ。処理中はスピナーを添える。
    @ViewBuilder
    private var statusHeader: some View {
        HStack(spacing: 8) {
            switch article.status {
            case .queued:
                ProgressView().controlSize(.small)
                Text("待機中")
            case .processing:
                ProgressView().controlSize(.small)
                Text("処理中")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("失敗")
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("完了")
            }
        }
        .textCase(nil)
    }

    private func row(for entry: ArticleLogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(entry.localizedMessage)
                .font(.callout)
                .foregroundStyle(entry.isError ? .red : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .listRowSeparator(.hidden)
    }
}
