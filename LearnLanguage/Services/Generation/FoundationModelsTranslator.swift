import Foundation
import FoundationModels
import os

/// FoundationModels（オンデバイス）で本文を学習者の母語へ翻訳する。
/// 記事の書き換えと同様、既存コンテンツの変換なのでガードレールを緩めたモデルを使う。
struct FoundationModelsTranslator {
    private static let logger = Logger(subsystem: "com.mtkg.LearnLanguage", category: "Translate")

    private let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)

    enum TranslationError: LocalizedError {
        case unavailable
        case empty

        var errorDescription: String? {
            switch self {
            case .unavailable: return "オンデバイスの言語モデルが利用できません（Apple Intelligence を有効にしてください）。"
            case .empty: return "翻訳結果が空でした。"
            }
        }
    }

    /// `text` を母語（`languageCode`）へ翻訳して返す。
    func translate(_ text: String, to languageCode: String) async throws -> String {
        guard case .available = SystemLanguageModel.default.availability else {
            throw TranslationError.unavailable
        }
        let languageName = Self.languageName(for: languageCode)
        let instructions = """
        You are a professional translator. Translate the user's text into \(languageName) (\(languageCode)). \
        Output only the translation as natural prose — no notes, labels, explanations, or quotation marks. \
        Preserve the meaning, names, and numbers faithfully.
        """
        let session = LanguageModelSession(model: model, instructions: instructions)
        let response = try await session.respond(
            to: text,
            options: GenerationOptions(temperature: 0.2)
        )
        let result = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw TranslationError.empty }
        return result
    }

    /// 言語コードを英語名にする（プロンプトへ埋め込む用）。例: "ja" → "Japanese"。
    static func languageName(for code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }
}
