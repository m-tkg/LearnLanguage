import SwiftUI

/// 長押しされた単語。sheet(item:) で使うための Identifiable ラッパ。
struct WordSelection: Identifiable {
    let id = UUID()
    let word: String
}

/// 単語の意味（母語）を表示する下部シート。
/// 用語集に訳があれば即表示し、無ければ Foundation Models（オンデバイス）で翻訳して表示する。
struct WordMeaningSheet: View {
    let word: String
    /// 用語集から引けた訳（あれば AI を呼ばずに使う）。
    let glossaryTranslation: String?
    let nativeLanguageCode: String

    @State private var meaning: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(word)
                .font(.title2.bold())
            Group {
                if let translation = glossaryTranslation ?? meaning {
                    Text(translation)
                        .font(.body)
                } else if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("意味を調べています…").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .task {
            guard glossaryTranslation == nil else { return }
            do {
                meaning = try await FoundationModelsTranslator().translate(word, to: nativeLanguageCode)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
