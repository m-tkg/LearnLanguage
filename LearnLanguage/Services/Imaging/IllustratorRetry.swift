import Foundation
import os

/// イラスト生成プロバイダ共通のリトライループ。
/// 429・5xx・通信エラーなど「待てば回復しうる失敗」を指数バックオフで再試行する
/// （Pollinations は Cloudflare 経由のため 530 等の一時障害が出やすい。Workers AI も同様）。
enum IllustratorRetry {
    private static let logger = Logger(subsystem: "com.mtkg.LearnLanguage", category: "Illustration")
    static let maxAttempts = 4

    /// `attempt` は 1 回分のリクエストを行い、(結果, 待てば回復しうる失敗か) を返す。
    /// 成功または回復不能な失敗で即返し、回復しうる失敗は最大 `maxAttempts` 回まで再試行する。
    static func run(
        baseDelay: TimeInterval,
        _ attempt: () async -> (IllustrationResult, retryable: Bool)
    ) async -> IllustrationResult {
        var result = IllustrationResult.failure(reason: "通信に失敗しました。")
        for index in 0..<maxAttempts {
            let (outcome, retryable) = await attempt()
            result = outcome
            if case .success = outcome { return outcome }
            guard retryable, index < maxAttempts - 1 else { break }
            let wait = baseDelay * Double(1 << (index + 1))
            logger.info("illustration retrying in \(wait, privacy: .public)s (attempt \(index + 1, privacy: .public))")
            try? await Task.sleep(for: .seconds(wait))
        }
        return result
    }
}
