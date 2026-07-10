import Foundation
import os

/// Cloudflare Workers AI（FLUX.1 schnell）でイラストを生成する。
/// 無料枠が日次で付与され可用性が高い。Account ID と API トークンの 2 つを Keychain（BYOK）から読む。
/// - Account ID: Cloudflare ダッシュボード右側（または URL）に表示される 32 桁の英数字。
/// - API トークン: 「Workers AI: 読み取り/実行」権限で発行したトークン。
struct CloudflareIllustrator: IllustrationGenerating {
    private static let logger = Logger(subsystem: "com.mtkg.LearnLanguage", category: "Illustration")

    /// 画像生成モデル。無料枠内で高速・正方形出力の FLUX schnell を既定にする。
    var model: String = "@cf/black-forest-labs/flux-1-schnell"
    var accountID: @Sendable () -> String? = { KeychainStore.get(account: KeychainStore.cloudflareAccountIDAccount) }
    var apiToken: @Sendable () -> String? = { KeychainStore.get(account: KeychainStore.cloudflareAPITokenAccount) }
    /// テストでネットワークをモックするための差し替え口。
    var session: URLSession = .shared
    /// リトライのバックオフ基準秒。テストでは 0 にして待ちを消す。
    var retryBaseDelay: TimeInterval = 1

    func illustrate(prompt: String) async -> IllustrationResult {
        let account = accountID()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = apiToken()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !account.isEmpty, !token.isEmpty else {
            return .failure(reason: "Cloudflare の Account ID と API トークンが未設定です。設定画面で入力してください。")
        }
        guard let url = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(account)/ai/run/\(model)") else {
            return .failure(reason: "画像URLの生成に失敗しました。")
        }
        return await IllustratorRetry.run(baseDelay: retryBaseDelay) {
            await requestOnce(url: url, token: token, prompt: Self.styledPrompt(prompt))
        }
    }

    /// 学習向けのスタイルを付与したプロンプト（FLUX schnell は既定で正方形出力）。
    static func styledPrompt(_ prompt: String) -> String {
        "\(prompt). \(IllustrationPrompt.baseStyle), no text or letters"
    }

    private func requestOnce(url: URL, token: String, prompt: String) async -> (IllustrationResult, retryable: Bool) {
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder().encode(GenerateRequest(prompt: prompt))

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return (.failure(reason: "通信に失敗しました。"), true)
            }
            guard http.statusCode == 200 else {
                // 認証エラーは待っても直らない → 原因の切り分けを具体的に案内する。
                if http.statusCode == 401 || http.statusCode == 403 {
                    return (.failure(reason: "Cloudflare の認証に失敗しました(\(http.statusCode))。「API トークン」（Bearer 用）を使っているか（Global API Key は不可）、トークンに Workers AI の権限があるか、Account ID が正しいかを確認してください。"), false)
                }
                let message = Self.errorMessage(from: data)
                let retryable = http.statusCode == 429 || (500...599).contains(http.statusCode)
                return (.failure(reason: "Cloudflare APIエラー(\(http.statusCode))\(message.map { ": \($0)" } ?? "")。"),
                        retryable)
            }
            guard let decoded = try? JSONDecoder().decode(GenerateResponse.self, from: data),
                  let base64 = decoded.result?.image,
                  let imageData = Data(base64Encoded: base64), !imageData.isEmpty else {
                return (.failure(reason: "画像が返りませんでした。プロンプトを変えて再試行してください。"), false)
            }
            return (.success(imageData), false)
        } catch {
            Self.logger.error("Cloudflare request failed: \(String(describing: error), privacy: .public)")
            return (.failure(reason: "通信エラー: \(error.localizedDescription)"), true)
        }
    }

    private static func errorMessage(from data: Data) -> String? {
        (try? JSONDecoder().decode(GenerateResponse.self, from: data))?.errors?.first?.message
    }

    // MARK: - Codable（Workers AI REST）

    private struct GenerateRequest: Encodable {
        let prompt: String
        /// 推論ステップ数。schnell は 4 ステップ蒸留モデルで 4 が推奨値。
        /// 8（上限）だと 96 Neurons/枚、4 だと 57.6 Neurons/枚で無料枠(10,000/日)の持ちが約1.7倍になる。
        var steps: Int = 4
    }

    private struct GenerateResponse: Decodable {
        struct ResultBody: Decodable { let image: String? }
        struct APIError: Decodable { let message: String? }
        let result: ResultBody?
        let errors: [APIError]?
    }
}
