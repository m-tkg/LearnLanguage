import SwiftUI
import SwiftData

/// 学習画面。セグメントごとにページングし、上部にイラスト固定・下部に本文スクロール。
/// 読み上げボタンと速度スライダーを備える。
struct ReaderView: View {
    let article: LearningArticle

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    /// 設定のデフォルト速度（記事に速度未設定のときの初期値）。
    @AppStorage("speechRate") private var defaultSpeechRate = 0.5
    /// 翻訳先の母語（設定に追従。設定で変更すると記事内の翻訳先も変わる）。
    @AppStorage("nativeLanguageCode") private var nativeLanguageCode = "ja"
    @State private var speaker = SpeechService()
    @State private var currentIndex = 0
    /// 元記事のアプリ内ブラウザ表示。
    @State private var showingSource = false

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
            #if os(iOS)
            TabView(selection: $currentIndex) {
                ForEach(Array(segments.enumerated()), id: \.element.persistentModelID) { index, segment in
                    SegmentPageView(segment: segment, nativeLanguageCode: nativeLanguageCode)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: segments.count > 1 ? .always : .never))
            #else
            // macOS はページング TabView が無いため、現在のセグメント表示＋前後ボタンで送る。
            if segments.indices.contains(currentIndex) {
                SegmentPageView(segment: segments[currentIndex], nativeLanguageCode: nativeLanguageCode)
                    .id(segments[currentIndex].persistentModelID)
            }
            if segments.count > 1 {
                HStack(spacing: 16) {
                    Button {
                        currentIndex -= 1
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(currentIndex <= 0)
                    Text(verbatim: "\(currentIndex + 1) / \(segments.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        currentIndex += 1
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(currentIndex >= segments.count - 1)
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 6)
            }
            #endif

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
        .inlineNavigationBarTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    #if os(iOS)
                    showingSource = true
                    #else
                    // macOS はアプリ内ブラウザ（SFSafariViewController）が無いため既定ブラウザで開く。
                    openURL(article.sourceURL)
                    #endif
                } label: {
                    Label("元記事を開く", systemImage: "safari")
                }
                // SFSafariViewController は http/https のみ対応（macOS も http/https に限定）。
                .disabled(!["http", "https"].contains(article.sourceURL.scheme?.lowercased() ?? ""))
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showingSource) {
            SafariView(url: article.sourceURL)
                .ignoresSafeArea()
        }
        #endif
        .onDisappear { speaker.stop() }
    }
}

#Preview {
    NavigationStack {
        ReaderView(article: SampleData.makeArticle())
    }
}
