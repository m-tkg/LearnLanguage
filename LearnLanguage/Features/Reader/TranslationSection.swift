import SwiftUI

/// 本文を母語に翻訳するボタンと、その結果表示。
struct TranslationSection: View {
    let controller: TranslationController
    let nativeLanguageCode: String
    let segmentText: String

    var body: some View {
        Divider()
        Button {
            Task { await controller.toggle(text: segmentText, to: nativeLanguageCode) }
        } label: {
            Label(
                controller.translation == nil
                    ? LocalizedStringKey("\(nativeLanguageDisplayName)に翻訳")
                    : LocalizedStringKey("翻訳を隠す"),
                systemImage: "character.book.closed"
            )
        }
        .disabled(controller.isTranslating)

        if controller.isTranslating {
            HStack(spacing: 8) {
                ProgressView()
                Text("翻訳中…").foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        if let errorMessage = controller.errorMessage {
            Text(errorMessage)
                .font(.callout)
                .foregroundStyle(.red)
        }
        if let translation = controller.translation {
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
}
