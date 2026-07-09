import Foundation

/// セグメント本文の母語翻訳（Foundation Models・オンデバイス）の状態と実行を管理する。
@MainActor
@Observable
final class TranslationController {
    private(set) var translation: String?
    private(set) var isTranslating = false
    private(set) var errorMessage: String?

    /// 翻訳の表示/非表示をトグルする。表示時に未翻訳なら Foundation Models で翻訳する。
    func toggle(text: String, to languageCode: String) async {
        if translation != nil {
            translation = nil
            return
        }
        isTranslating = true
        errorMessage = nil
        defer { isTranslating = false }
        do {
            translation = try await FoundationModelsTranslator().translate(text, to: languageCode)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 母語（設定）が変わったら、既存の翻訳表示は破棄する（押し直すと新しい母語で翻訳）。
    func reset() {
        translation = nil
        errorMessage = nil
    }
}
