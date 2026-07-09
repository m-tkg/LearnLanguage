import Foundation
import os

/// Google Gemini（Gemini 2.5 Flash Image / 通称 Nano Banana）でイラストを生成する。
/// 無料枠があり個人利用に向く。API キーは Keychain（BYOK）から読む。
/// HTTP 送受信・リトライ・エラー分類は `GeminiClient` に委譲する。
struct GeminiIllustrator: IllustrationGenerating {
    private static let logger = Logger(subsystem: "com.mtkg.LearnLanguage", category: "Illustration")

    /// 画像生成モデル。無料枠のある Flash Image を既定にする。
    var model: String = "gemini-2.5-flash-image"
    /// API キーの供給元（既定は Keychain）。テストで差し替え可能。
    var apiKey: @Sendable () -> String? = { KeychainStore.get(account: KeychainStore.geminiAPIKeyAccount) }

    func illustrate(prompt: String) async -> IllustrationResult {
        let body = GenerateRequest(
            contents: [.init(parts: [.init(text: Self.styledPrompt(prompt))])],
            generationConfig: .init(responseModalities: ["IMAGE"])
        )
        do {
            let data = try await GeminiClient.send(model: model, body: body, apiKey: apiKey())
            guard let base64 = Self.decode(data), let imageData = Data(base64Encoded: base64) else {
                return .failure(reason: "画像が返りませんでした。プロンプトを変えて再試行してください。")
            }
            return .success(imageData)
        } catch {
            Self.logger.error("Gemini illustration request failed: \(String(describing: error), privacy: .public)")
            return .failure(reason: error.localizedDescription)
        }
    }

    /// 学習向けのスタイルを付与したプロンプト。
    static func styledPrompt(_ prompt: String) -> String {
        "\(prompt). \(IllustrationPrompt.baseStyle), suitable for a language-learning app. "
            + "Square 1:1 aspect ratio composition. "
            + "Do not include any text or letters in the image."
    }

    private static func decode(_ data: Data) -> String? {
        guard let decoded = try? JSONDecoder().decode(GenerateResponse.self, from: data) else { return nil }
        return decoded.candidates?
            .compactMap({ $0.content?.parts }).flatMap({ $0 })
            .compactMap({ $0.inlineData?.data }).first
    }

    // MARK: - Codable（Gemini REST v1beta）

    private struct GenerateRequest: Encodable {
        struct Content: Encodable { let parts: [Part] }
        struct Part: Encodable { let text: String }
        struct Config: Encodable { let responseModalities: [String] }
        let contents: [Content]
        let generationConfig: Config
    }

    private struct GenerateResponse: Decodable {
        struct Candidate: Decodable { let content: Content? }
        struct Content: Decodable { let parts: [Part]? }
        struct Part: Decodable { let inlineData: InlineData? }
        struct InlineData: Decodable { let mimeType: String?; let data: String? }
        let candidates: [Candidate]?
    }
}
