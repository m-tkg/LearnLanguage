import Foundation
import os

/// Gemini API（`{model}:generateContent`）への低レベル HTTP アクセスを一元化する。
/// エンドポイント構築・認証ヘッダ（`x-goog-api-key`）・リトライ/バックオフ・エラー分類
/// （401/403 即失敗・1日無料枠上限は即失敗・429/5xx はリトライ）を持つ。
/// リクエストボディの組み立てとレスポンスの意味解釈（テキスト取り出し・画像取り出し等）は
/// 呼び出し側（Rewriter/Illustrator/Extractor）の責務のまま残す。
///
/// 以前は `GeminiRewriter`・`GeminiIllustrator`・`ArticleContentExtractor.extractViaGemini` の
/// 3箇所に別々の HTTP クライアントがあり、429/PerDay/認証エラーの扱いが場所ごとに異なっていた
/// （特にイラスト生成にはリトライが一切無かった）。ここへ統一することで挙動を揃える。
enum GeminiClient {
    private static let logger = Logger(subsystem: "com.mtkg.LearnLanguage", category: "GeminiClient")

    enum ClientError: LocalizedError {
        case noKey
        case api(status: Int, message: String, retryAfter: TimeInterval?)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .noKey: return "Gemini APIキーが未設定です。設定画面で入力してください。"
            case .api(let status, let message, _): return "Gemini APIエラー(\(status)): \(message)"
            case .emptyResponse: return "Gemini から有効な応答がありませんでした。"
            }
        }
    }

    private static let retryableStatuses: Set<Int> = [429, 500, 502, 503, 504]
    private static let maxAttempts = 6
    private static let maxRetryDelay: TimeInterval = 65

    /// `model:generateContent` へ POST し、リトライ・エラー分類込みで生の応答 `Data` を返す。
    /// ボディの組み立て（JSON モード指定・tools・generationConfig 等）は呼び出し側の `Encodable` が担う。
    /// `session` はテストでネットワークをモックするための差し替え口（既定は `.shared`）。
    static func send(
        model: String,
        body: some Encodable,
        apiKey: String?,
        timeout: TimeInterval = 180,
        session: URLSession = .shared
    ) async throws -> Data {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { throw ClientError.noKey }

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        let bodyData = try JSONEncoder().encode(body)

        var lastError: any Error = ClientError.emptyResponse
        for attempt in 0..<maxAttempts {
            var retryAfter: TimeInterval?
            do {
                return try await sendOnce(url: url, bodyData: bodyData, key: key, timeout: timeout, session: session)
            } catch let error as ClientError {
                guard case .api(let status, _, let suggested) = error, retryableStatuses.contains(status) else {
                    throw error
                }
                // サーバー指定の待機が上限(65秒)を超える＝1日上限など長時間 → すぐ諦めて失敗表示にする。
                if let suggested, suggested > maxRetryDelay { throw error }
                lastError = error
                retryAfter = suggested
            } catch {
                lastError = error
            }
            if attempt < maxAttempts - 1 {
                let backoff = Double(1 << (attempt + 1))
                let wait = min(max(retryAfter ?? backoff, backoff), maxRetryDelay)
                try? await Task.sleep(for: .seconds(wait))
            }
        }
        throw lastError
    }

    private static func sendOnce(url: URL, bodyData: Data, key: String, timeout: TimeInterval, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // キーはクエリ(?key=)ではなく Google 推奨のヘッダで送る（URL エンコードの端ケースを回避）。
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = bodyData

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.emptyResponse }
        guard http.statusCode == 200 else {
            let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
            // 認証エラーは待っても直らない → 即失敗し、キーの貼り直し等を案内する。
            if http.statusCode == 401 || http.statusCode == 403 {
                throw ClientError.api(
                    status: http.statusCode,
                    message: "APIキーが認証されませんでした。Google AI Studio で発行した Gemini API キーを設定に貼り直し、キーの利用制限（API/アプリ制限）や、対象プロジェクトで Generative Language API が有効かを確認してください。",
                    retryAfter: nil
                )
            }
            // 1日あたりの無料枠上限は待っても回復しない → 即失敗（retryAfter を大きくして fail-fast）。
            if envelope?.isPerDayLimit == true {
                throw ClientError.api(
                    status: http.statusCode,
                    message: "無料枠の1日上限に達しました（翌日リセット）。設定でモデルを変えるか、時間をおくか、billing を有効化してください。",
                    retryAfter: 3600
                )
            }
            throw ClientError.api(status: http.statusCode, message: envelope?.error.message ?? "", retryAfter: envelope?.retryAfter)
        }
        return data
    }

    /// テキスト応答から最初の候補のテキストを取り出す（Rewriter/Extractor 用の共通ヘルパ）。
    static func firstText(from data: Data) -> String? {
        guard let decoded = try? JSONDecoder().decode(GenerateResponse.self, from: data) else { return nil }
        return decoded.candidates?
            .compactMap({ $0.content?.parts?.compactMap(\.text).joined() })
            .first(where: { !$0.isEmpty })
    }

    private struct GenerateResponse: Decodable {
        struct Candidate: Decodable { let content: Content? }
        struct Content: Decodable { let parts: [Part]? }
        struct Part: Decodable { let text: String? }
        let candidates: [Candidate]?
    }

    // MARK: - エラー本文の解析（Gemini 共通のエラーレスポンス形式）

    private struct ErrorEnvelope: Decodable {
        struct APIError: Decodable {
            let message: String
            let details: [Detail]?
        }
        struct Detail: Decodable {
            let retryDelay: String?
            let violations: [Violation]?
        }
        struct Violation: Decodable { let quotaId: String? }
        let error: APIError

        var retryAfter: TimeInterval? {
            guard let raw = error.details?.compactMap(\.retryDelay).first else { return nil }
            return TimeInterval(raw.hasSuffix("s") ? String(raw.dropLast()) : raw)
        }

        /// 1日あたり（PerDay）の上限超過か。retryDelay が短くても待っても回復しない。
        var isPerDayLimit: Bool {
            error.details?.contains { detail in
                (detail.violations ?? []).contains { ($0.quotaId ?? "").localizedCaseInsensitiveContains("PerDay") }
            } ?? false
        }
    }
}
