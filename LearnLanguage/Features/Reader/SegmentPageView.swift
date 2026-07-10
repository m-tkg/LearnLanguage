import SwiftUI
import SwiftData

/// 1 セグメントのページ。上部にイラスト固定、下部に本文と用語集をスクロール表示。
struct SegmentPageView: View {
    let segment: ArticleSegment
    /// 翻訳先の母語コード（設定に追従）。
    let nativeLanguageCode: String

    @Environment(\.modelContext) private var modelContext
    @State private var translationController = TranslationController()
    /// 長押しで意味を表示する対象の単語。
    @State private var wordSelection: WordSelection?

    var body: some View {
        GeometryReader { geo in
            // 横長（横向き）なら左に画像・右に本文、縦長なら上に画像・下に本文。
            let landscape = geo.size.width > geo.size.height
            // イラストは正方形固定。縦長は幅の半分（縦横それぞれ半分）、横長は高さ（かつ画面の半分まで）基準。
            let side = landscape ? min(geo.size.height, geo.size.width * 0.5) : geo.size.width / 2
            Group {
                if landscape {
                    HStack(spacing: 0) {
                        illustration(side: side)
                        textContent
                    }
                } else {
                    VStack(spacing: 0) {
                        illustration(side: side)
                        textContent
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // 母語（設定）が変わったら、既存の翻訳表示は破棄する（押し直すと新しい母語で翻訳）。
        .onChange(of: nativeLanguageCode) { _, _ in
            translationController.reset()
        }
        // 単語の長押し → 意味（母語）を下部シートで表示する。
        .sheet(item: $wordSelection) { selection in
            WordMeaningSheet(
                word: selection.word,
                glossaryTranslation: glossaryTranslation(for: selection.word),
                nativeLanguageCode: nativeLanguageCode
            )
            .presentationDetents([.height(200)])
            .presentationDragIndicator(.visible)
        }
    }

    /// 用語集から単語の訳を引く（surface 完全一致を優先、複数語 surface の構成語も許容）。
    private func glossaryTranslation(for word: String) -> String? {
        let lowered = word.lowercased()
        if let exact = segment.glossary.first(where: { $0.surface.lowercased() == lowered }) {
            return exact.translation
        }
        return segment.glossary.first { term in
            term.surface.lowercased().split(separator: " ").contains(Substring(lowered))
        }?.translation
    }

    /// 正方形のイラスト枠（生成画像も正方形なので歪まない）。失敗時は上部に「再作成」ボタンを出す。
    private func illustration(side: CGFloat) -> some View {
        IllustrationView(segment: segment)
            .frame(width: side, height: side)
            .background(.quaternary)
            .clipped()
            .overlay(alignment: .top) {
                if segment.imageState == .failed {
                    Button("再作成", systemImage: "arrow.clockwise") {
                        Task { await generateIllustration() }
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(8)
                }
            }
    }

    /// このセグメントのイラストを生成し直す（失敗時の「再作成」ボタン）。生成中は imageState でスピナー表示。
    private func generateIllustration() async {
        segment.imageState = .generating
        segment.imageFailureReason = nil
        try? modelContext.save()
        let prompt = IllustrationPrompt.resolve(
            imagePrompt: segment.imagePrompt,
            fallbackText: segment.rewrittenText
        )
        switch await IllustratorFactory.live().illustrate(prompt: prompt) {
        case .success(let data):
            segment.imageData = data
            segment.imageFailureReason = nil
            segment.imageState = .ready
        case .failure(let reason):
            segment.imageFailureReason = reason
            segment.imageState = .failed
        }
        try? modelContext.save()
    }

    /// 本文と用語集のスクロール領域。
    private var textContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                WordTappableText(
                    text: segment.rewrittenText,
                    glossarySurfaces: segment.glossary.map(\.surface),
                    onWordLongPress: { word in wordSelection = WordSelection(word: word) }
                )
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)

                TranslationSection(
                    controller: translationController,
                    nativeLanguageCode: nativeLanguageCode,
                    segmentText: segment.rewrittenText
                )

                if !segment.glossary.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("単語")
                            .font(.headline)
                        ForEach(segment.glossary, id: \.persistentModelID) { term in
                            HStack(alignment: .firstTextBaseline) {
                                Text(term.surface).fontWeight(.semibold)
                                Text("—").foregroundStyle(.secondary)
                                Text(term.translation).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding()
            // ページのドットインジケータ（最下部にオーバーレイ表示）と本文末尾が重ならないよう余白を確保。
            .padding(.bottom, 44)
        }
        // 通信のやり直しはせず、現在の状態表示を更新するだけ（イラスト生成はキューが自動実行）。
        .refreshable { try? await Task.sleep(for: .milliseconds(400)) }
    }
}
