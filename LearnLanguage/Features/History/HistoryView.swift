import SwiftUI
import SwiftData

/// 生成済み・生成中の記事一覧。生成中はスピナー表示。タップで学習画面へ、スワイプで削除/お気に入り。
/// Pull to refresh で失敗・中断した記事を再試行する。
struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(GenerationQueue.self) private var queue
    /// 再生成時に使う学習対象言語（設定の現在値に自動追従）。
    @AppStorage("targetLanguageCode") private var targetLanguageCode = "en"
    // 手動並び替え順（sortIndex 昇順）を主、同値は作成日の新しい順。
    @Query(sort: [SortDescriptor(\LearningArticle.sortIndex, order: .forward),
                  SortDescriptor(\LearningArticle.createdAt, order: .reverse)])
    private var articles: [LearningArticle]
    /// 長押しで処理ログを表示する対象。
    @State private var logArticle: LearningArticle?
    /// 追加画面（ポップアップ）の表示。
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            Group {
                if articles.isEmpty {
                    ContentUnavailableView(
                        "記事はありません",
                        systemImage: "doc.text",
                        description: Text("右上の＋から記事の URL を指定して教材を作成します。")
                    )
                } else {
                    List {
                        ForEach(articles) { article in
                            row(for: article)
                                // 長押しメニュー（行タップ＝Reader への遷移とは両立）。
                                .contextMenu {
                                    if article.status == .failed {
                                        Button {
                                            queue.retry(article)
                                        } label: {
                                            Label("再実行", systemImage: "arrow.clockwise")
                                        }
                                    }
                                    // 現在の学習対象言語（設定）で最初から作り直す（実行した端末が生成を担当）。
                                    Button {
                                        queue.regenerate(article, targetLanguageCode: targetLanguageCode)
                                    } label: {
                                        Label("再生成", systemImage: "arrow.triangle.2.circlepath")
                                    }
                                    Button {
                                        logArticle = article
                                    } label: {
                                        Label("処理ログを見る", systemImage: "text.alignleft")
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        article.isFavorite.toggle()
                                    } label: {
                                        Label(article.isFavorite ? LocalizedStringKey("解除") : LocalizedStringKey("お気に入り"),
                                              systemImage: article.isFavorite ? "star.slash" : "star")
                                    }
                                    .tint(.yellow)
                                }
                        }
                        .onDelete(perform: delete)
                        .onMove(perform: move)
                    }
                    // 通信のやり直しはせず、現在の状態表示を更新するだけ（@Query はライブ）。
                    .refreshable { try? await Task.sleep(for: .milliseconds(400)) }
                }
            }
            .navigationTitle("記事")
            .toolbar {
                // EditButton（編集モード）は iOS 専用。macOS は行のドラッグ/コンテキストメニューで代替できる。
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    if !articles.isEmpty { EditButton() }
                }
                #endif
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("記事を追加", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(for: LearningArticle.self) { article in
                ReaderView(article: article)
            }
            .sheet(item: $logArticle) { article in
                ArticleLogView(article: article)
            }
            .sheet(isPresented: $showingAdd) {
                HomeView()
            }
        }
    }

    /// 本文（セグメント）が用意できたらタップで学習画面へ（イラスト未完でも可）。
    /// 本文取得前（セグメント無し）や失敗はタップ不可の行にする。
    @ViewBuilder
    private func row(for article: LearningArticle) -> some View {
        if !article.segments.isEmpty {
            NavigationLink(value: article) {
                HistoryRow(article: article)
            }
        } else {
            HistoryRow(article: article)
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(articles[index])
        }
    }

    /// 手動並び替え。並べ替え後の順序で sortIndex を 0 から振り直す。
    private func move(from source: IndexSet, to destination: Int) {
        var reordered = articles
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, article) in reordered.enumerated() {
            article.sortIndex = index
        }
        try? modelContext.save()
    }
}
