import Foundation
import os

/// Pollinations.ai（キー不要・無料）でイラストを生成する。
/// 短い視覚プロンプトを GET で渡すと画像が返る。課金不要で自動生成できるため既定にする。
/// 注: 第三者の無料サービスへ短いプロンプトを送信する（記事本文は送らない）。
struct PollinationsIllustrator: IllustrationGenerating {
    private static let logger = Logger(subsystem: "com.mtkg.LearnLanguage", category: "Illustration")

    // 表示は正方形固定なので生成も正方形にする。
    var width = 768
    var height = 768
    /// 任意の Pollinations API キー（Seed tier でレート緩和）。既定は Keychain から読む。
    var apiKey: @Sendable () -> String? = { KeychainStore.get(account: KeychainStore.pollinationsAPIKeyAccount) }
    /// テストでネットワークをモックするための差し替え口。
    var session: URLSession = .shared
    /// リトライのバックオフ基準秒（attempt に対し 2^(attempt+1) 倍）。テストでは 0 にして待ちを消す。
    var retryBaseDelay: TimeInterval = 1

    /// 429（レート制限）と 5xx（Pollinations は Cloudflare 経由のため 530 等の一時障害が出やすい）はリトライする。
    private static let maxAttempts = 4

    func illustrate(prompt: String) async -> IllustrationResult {
        guard let url = Self.makeURL(prompt: prompt, width: width, height: height) else {
            return .failure(reason: "画像URLの生成に失敗しました。")
        }
        var result = IllustrationResult.failure(reason: "通信に失敗しました。")
        for attempt in 0..<Self.maxAttempts {
            let (outcome, retryable) = await requestOnce(url: url)
            result = outcome
            if case .success = outcome { return outcome }
            guard retryable, attempt < Self.maxAttempts - 1 else { break }
            let wait = retryBaseDelay * Double(1 << (attempt + 1))
            Self.logger.info("Pollinations retrying in \(wait, privacy: .public)s (attempt \(attempt + 1, privacy: .public))")
            try? await Task.sleep(for: .seconds(wait))
        }
        return result
    }

    /// 1 回だけリクエストする。戻り値の retryable は「待てば回復しうる失敗（429/5xx/通信エラー）」か。
    private func requestOnce(url: URL) async -> (IllustrationResult, retryable: Bool) {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            // キーがあれば Bearer 認証でレート制限を緩和（15秒→5秒/回）。
            if let key = apiKey(), !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return (.failure(reason: "通信に失敗しました。"), true)
            }
            guard http.statusCode == 200 else {
                let retryable = http.statusCode == 429 || (500...599).contains(http.statusCode)
                return (.failure(reason: "画像生成に失敗しました（HTTP \(http.statusCode)）。時間をおいて再試行してください。"),
                        retryable)
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            guard contentType.hasPrefix("image"), !data.isEmpty else {
                return (.failure(reason: "画像を取得できませんでした。時間をおいて再試行してください。"), false)
            }
            return (.success(data), false)
        } catch {
            Self.logger.error("Pollinations request failed: \(String(describing: error), privacy: .public)")
            return (.failure(reason: "通信エラー: \(error.localizedDescription)"), true)
        }
    }

    /// 学習向けスタイルを付与したプロンプト。
    static func styledPrompt(_ prompt: String) -> String {
        "\(prompt). \(IllustrationPrompt.baseStyle), no text or letters"
    }

    /// Pollinations の画像 URL を組み立てる（プロンプトはパスに percent-encode して埋め込む）。
    static func makeURL(prompt: String, width: Int, height: Int) -> URL? {
        let styled = styledPrompt(prompt)
        guard let encoded = styled.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "image.pollinations.ai"
        components.percentEncodedPath = "/prompt/" + encoded
        components.queryItems = [
            URLQueryItem(name: "width", value: "\(width)"),
            URLQueryItem(name: "height", value: "\(height)"),
            URLQueryItem(name: "nologo", value: "true"),
        ]
        return components.url
    }
}
