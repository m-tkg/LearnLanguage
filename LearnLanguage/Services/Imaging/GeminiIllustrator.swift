import Foundation
import os

/// Google Gemini（Gemini 2.5 Flash Image / 通称 Nano Banana）でイラストを生成する。
/// 無料枠があり個人利用に向く。API キーは Keychain（BYOK）から読む。
struct GeminiIllustrator: IllustrationGenerating {
    private static let logger = Logger(subsystem: "com.mtkg.LearnLanguage", category: "Illustration")

    /// 画像生成モデル。無料枠のある Flash Image を既定にする。
    var model: String = "gemini-2.5-flash-image"
    /// API キーの供給元（既定は Keychain）。テストで差し替え可能。
    var apiKey: @Sendable () -> String? = { KeychainStore.get(account: KeychainStore.geminiAPIKeyAccount) }

    func illustrate(prompt: String) async -> IllustrationResult {
        guard let key = apiKey(), !key.isEmpty else {
            return .failure(reason: "Gemini APIキーが未設定です。設定画面で入力してください。")
        }
        do {
            return try await request(prompt: Self.styledPrompt(prompt), key: key)
        } catch {
            Self.logger.error("Gemini request failed: \(String(describing: error), privacy: .public)")
            return .failure(reason: "通信エラー: \(error.localizedDescription)")
        }
    }

    /// 学習向けのスタイルを付与したプロンプト。
    static func styledPrompt(_ prompt: String) -> String {
        "\(prompt). 2D Japanese anime style illustration, clean line art, cel shading, soft vibrant colors, "
            + "friendly and appealing, a detailed and descriptive scene that clearly depicts the situation "
            + "so the content is easy to understand at a glance, suitable for a language-learning app. "
            + "Square 1:1 aspect ratio composition. "
            + "Do not include any text or letters in the image."
    }

    private func request(prompt: String, key: String) async throws -> IllustrationResult {
        var components = URLComponents(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        )!
        components.queryItems = [URLQueryItem(name: "key", value: key)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = GenerateRequest(
            contents: [.init(parts: [.init(text: prompt)])],
            generationConfig: .init(responseModalities: ["IMAGE"])
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return .failure(reason: "通信に失敗しました。")
        }
        guard http.statusCode == 200 else {
            if let apiError = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
                return .failure(reason: "Gemini APIエラー(\(http.statusCode)): \(apiError.error.message)")
            }
            return .failure(reason: "Gemini APIエラー(\(http.statusCode))。")
        }

        let decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
        guard let base64 = decoded.candidates?
            .compactMap({ $0.content?.parts }).flatMap({ $0 })
            .compactMap({ $0.inlineData?.data }).first,
            let imageData = Data(base64Encoded: base64) else {
            return .failure(reason: "画像が返りませんでした。プロンプトを変えて再試行してください。")
        }
        return .success(imageData)
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

    private struct ErrorEnvelope: Decodable {
        struct APIError: Decodable { let message: String }
        let error: APIError
    }
}
