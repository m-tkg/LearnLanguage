import SwiftUI
import SwiftData

/// 学習画面。セグメントごとにページングし、上部にイラスト固定・下部に本文スクロール。
/// 読み上げボタンと速度スライダーを備える。
struct ReaderView: View {
    let article: LearningArticle

    @Environment(\.modelContext) private var modelContext
    /// 設定のデフォルト速度（記事に速度未設定のときの初期値）。
    @AppStorage("speechRate") private var defaultSpeechRate = 0.5
    /// 翻訳先の母語（設定に追従。設定で変更すると記事内の翻訳先も変わる）。
    @AppStorage("nativeLanguageCode") private var nativeLanguageCode = "ja"
    @State private var speaker = SpeechService()
    @State private var currentIndex = 0

    private var segments: [ArticleSegment] {
        article.segments.sorted { $0.order < $1.order }
    }

    /// この記事だけの読み上げ速度。変更はこの記事に保存し、設定のデフォルトには影響させない。
    private var rateBinding: Binding<Double> {
        Binding(
            get: { article.speechRate ?? defaultSpeechRate },
            set: { article.speechRate = $0; try? modelContext.save() }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $currentIndex) {
                ForEach(Array(segments.enumerated()), id: \.element.persistentModelID) { index, segment in
                    SegmentPageView(segment: segment, nativeLanguageCode: nativeLanguageCode)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: segments.count > 1 ? .always : .never))

            PlaybackControls(
                rate: rateBinding,
                isSpeaking: speaker.isSpeaking,
                onPlay: {
                    guard segments.indices.contains(currentIndex) else { return }
                    speaker.speak(segments[currentIndex].rewrittenText,
                                  languageCode: article.languageCode,
                                  rate: Float(article.speechRate ?? defaultSpeechRate))
                },
                onStop: { speaker.stop() }
            )
        }
        .navigationTitle(article.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Link(destination: article.sourceURL) {
                    Label("元記事を開く", systemImage: "safari")
                }
            }
        }
        .onDisappear { speaker.stop() }
    }
}

/// 1 セグメントのページ。上部にイラスト固定、下部に本文と用語集をスクロール表示。
private struct SegmentPageView: View {
    let segment: ArticleSegment
    /// 翻訳先の母語コード（設定に追従）。
    let nativeLanguageCode: String

    @Environment(\.modelContext) private var modelContext
    @State private var translation: String?
    @State private var isTranslating = false
    @State private var translationError: String?

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
            translation = nil
            translationError = nil
        }
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

    /// 本文を母語に翻訳するボタンと、その結果表示（Foundation Models・オンデバイス）。
    @ViewBuilder
    private var translationSection: some View {
        Divider()
        Button {
            Task { await toggleTranslation() }
        } label: {
            Label(
                translation == nil ? LocalizedStringKey("\(nativeLanguageDisplayName)に翻訳") : LocalizedStringKey("翻訳を隠す"),
                systemImage: "character.book.closed"
            )
        }
        .disabled(isTranslating)

        if isTranslating {
            HStack(spacing: 8) {
                ProgressView()
                Text("翻訳中…").foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        if let translationError {
            Text(translationError)
                .font(.callout)
                .foregroundStyle(.red)
        }
        if let translation {
            Text(translation)
                .font(.body)
                .lineSpacing(6)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 母語コードをその言語自身の名称にする（例: "ja" → "日本語"）。
    private var nativeLanguageDisplayName: String {
        Locale(identifier: nativeLanguageCode)
            .localizedString(forLanguageCode: nativeLanguageCode) ?? nativeLanguageCode
    }

    /// 翻訳の表示/非表示をトグルする。表示時に未翻訳なら Foundation Models で翻訳する。
    private func toggleTranslation() async {
        if translation != nil {
            translation = nil
            return
        }
        isTranslating = true
        translationError = nil
        defer { isTranslating = false }
        do {
            translation = try await FoundationModelsTranslator()
                .translate(segment.rewrittenText, to: nativeLanguageCode)
        } catch {
            translationError = error.localizedDescription
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
                Text(GlossaryHighlighter.attributedString(
                    for: segment.rewrittenText,
                    surfaces: segment.glossary.map(\.surface)
                ))
                .font(.body)
                .lineSpacing(6)
                .frame(maxWidth: .infinity, alignment: .leading)

                translationSection

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

/// セグメントのイラスト。生成済みなら画像、生成中はスピナー、未完/失敗はプレースホルダ。
private struct IllustrationView: View {
    let segment: ArticleSegment

    var body: some View {
        if let data = segment.imageData, let uiImage = UIImage(data: data) {
            // 縦横比を保ったまま枠内に収める（横向きなど枠が横長でも歪ませない）。
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
        } else if segment.imageState == .generating || segment.imageState == .pending {
            ProgressView("イラストを生成中…")
        } else {
            ContentUnavailableView {
                Label(placeholderTitle, systemImage: placeholderSymbol)
            } description: {
                if segment.imageState == .failed, let reason = segment.imageFailureReason {
                    Text(LocalizedStringKey(reason))
                }
            }
        }
    }

    private var placeholderTitle: String {
        switch segment.imageState {
        case .generating: return "イラストを生成中…"
        case .failed: return "イラストを生成できませんでした"
        default: return "イラストはありません"
        }
    }

    private var placeholderSymbol: String {
        segment.imageState == .failed ? "photo.badge.exclamationmark" : "photo"
    }
}

/// 読み上げの再生/停止トグルと速度スライダー。読み上げ中は「停止」ボタンになる。
private struct PlaybackControls: View {
    @Binding var rate: Double
    let isSpeaking: Bool
    let onPlay: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tortoise")
            Slider(value: $rate, in: 0...1)
            Image(systemName: "hare")
            Button {
                isSpeaking ? onStop() : onPlay()
            } label: {
                Image(systemName: isSpeaking ? "stop.fill" : "play.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderedProminent)
            .tint(isSpeaking ? .red : .accentColor)
            .accessibilityLabel(isSpeaking ? Text("停止") : Text("読み上げ"))
        }
        .padding()
        .background(.bar)
    }
}

#Preview {
    NavigationStack {
        ReaderView(article: SampleData.makeArticle())
    }
}
