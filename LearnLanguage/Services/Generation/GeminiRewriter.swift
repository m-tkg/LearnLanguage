import Foundation
import os

/// Gemini API（gemini-2.5-flash-lite・テキストは無料枠）で、抽出済み本文をレベル別に書き換える。
/// tools を使わないため **JSON モード（responseMimeType: application/json）**が効き、構造化出力が安定する。
/// 複数記事を1リクエストにまとめる `rewriteBatch` を持つ（レート上限対策）。API キーは Keychain（BYOK）。
struct GeminiRewriter: TextRewriting, BatchRewriting {
    private static let logger = Logger(subsystem: "com.mtkg.LearnLanguage", category: "Rewrite")

    var model: String = "gemini-2.5-flash-lite"
    var apiKey: @Sendable () -> String? = { KeychainStore.get(account: KeychainStore.geminiAPIKeyAccount) }

    enum RewriteError: LocalizedError {
        case noKey
        case api(Int, String, TimeInterval?)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .noKey: return "Gemini APIキーが未設定です。設定画面で入力してください。"
            case .api(let code, let message, _): return "Gemini APIエラー(\(code)): \(message)"
            case .emptyResponse: return "Gemini から有効な応答がありませんでした。"
            }
        }
    }

    // MARK: - 単一書き換え（TextRewriting 準拠）

    func rewrite(
        text: String,
        level: ReadingLevel,
        languageCode: String,
        nativeLanguageCode: String
    ) async throws -> [RewrittenSegment] {
        let results = try await rewriteBatch(
            [RewriteBatchItem(text: text, level: level, languageCode: languageCode)],
            nativeLanguageCode: nativeLanguageCode
        )
        guard let segments = results.first ?? nil, !segments.isEmpty else { throw RewriteError.emptyResponse }
        return segments
    }

    // MARK: - バッチ書き換え（複数記事を1リクエスト）

    func rewriteBatch(_ items: [RewriteBatchItem], nativeLanguageCode: String) async throws -> [[RewrittenSegment]?] {
        guard !items.isEmpty else { return [] }
        let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { throw RewriteError.noKey }

        let instruction = Self.instruction(nativeLanguageCode: nativeLanguageCode)
        let userText = Self.userText(items: items)
        let jsonText = try await request(instruction: instruction, userText: userText, key: key)

        guard let batch = Self.decode(BatchOutput.self, from: jsonText) else {
            Self.logger.error("Gemini rewrite: unparseable response: \(jsonText.prefix(400), privacy: .public)")
            throw RewriteError.emptyResponse
        }
        var results = [[RewrittenSegment]?](repeating: nil, count: items.count)
        for article in batch.articles {
            guard let index = article.index, index >= 1, index <= items.count else { continue }
            guard let segments = article.segments, !segments.isEmpty else { continue }
            results[index - 1] = Self.map(segments)
        }
        return results
    }

    private static func map(_ segments: [BatchOutput.Segment]) -> [RewrittenSegment] {
        segments.enumerated().map { index, segment in
            RewrittenSegment(
                order: index,
                text: segment.text,
                advancedTerms: (segment.advancedTerms ?? []).map { AdvancedTerm(surface: $0.surface, translation: $0.translation) },
                imagePrompt: segment.imagePrompt ?? ""
            )
        }
    }

    // MARK: - リクエスト（生 JSON テキストを返す・一時エラーはリトライ）

    private static let retryableStatuses: Set<Int> = [429, 500, 502, 503, 504]
    private static let maxAttempts = 6
    private static let maxRetryDelay: TimeInterval = 65

    private func request(instruction: String, userText: String, key: String) async throws -> String {
        var lastError: any Error = RewriteError.emptyResponse
        for attempt in 0..<Self.maxAttempts {
            var retryAfter: TimeInterval?
            do {
                return try await sendOnce(instruction: instruction, userText: userText, key: key)
            } catch let error as RewriteError {
                guard case .api(let code, _, let suggested) = error, Self.retryableStatuses.contains(code) else {
                    throw error
                }
                // サーバー指定の待機が上限(65秒)を超える＝1日上限など長時間 → すぐ諦めて失敗表示にする。
                if let suggested, suggested > Self.maxRetryDelay { throw error }
                lastError = error
                retryAfter = suggested
            } catch {
                lastError = error
            }
            if attempt < Self.maxAttempts - 1 {
                let backoff = Double(1 << (attempt + 1))
                let wait = min(max(retryAfter ?? backoff, backoff), Self.maxRetryDelay)
                try? await Task.sleep(for: .seconds(wait))
            }
        }
        throw lastError
    }

    private func sendOnce(instruction: String, userText: String, key: String) async throws -> String {
        let url = URL(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        )!

        var request = URLRequest(url: url, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // キーはクエリ(?key=)ではなく Google 推奨のヘッダで送る（URL エンコードの端ケースを回避）。
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        // tools を使わないので JSON モードが有効。
        let body = GenerateRequest(
            systemInstruction: .init(parts: [.init(text: instruction)]),
            contents: [.init(parts: [.init(text: userText)])],
            generationConfig: .init(responseMimeType: "application/json", temperature: 0.3)
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RewriteError.emptyResponse }
        guard http.statusCode == 200 else {
            let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
            // 認証エラーは待っても直らない → 即失敗し、キーの貼り直し等を案内する。
            if http.statusCode == 401 || http.statusCode == 403 {
                throw RewriteError.api(
                    http.statusCode,
                    "APIキーが認証されませんでした。Google AI Studio で発行した Gemini API キーを設定に貼り直し、キーの利用制限（API/アプリ制限）や、対象プロジェクトで Generative Language API が有効かを確認してください。",
                    nil
                )
            }
            // 1日あたりの無料枠上限は待っても回復しない → 即失敗（retryAfter を大きくして fail-fast）。
            if envelope?.isPerDayLimit == true {
                throw RewriteError.api(
                    http.statusCode,
                    "無料枠の1日上限に達しました（翌日リセット）。設定でモデルを変えるか、時間をおくか、billing を有効化してください。",
                    3600
                )
            }
            throw RewriteError.api(http.statusCode, envelope?.error.message ?? "", envelope?.retryAfter)
        }
        let decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
        let text = decoded.candidates?
            .compactMap({ $0.content?.parts?.compactMap(\.text).joined() })
            .first(where: { !$0.isEmpty })
        guard let text, !text.isEmpty else { throw RewriteError.emptyResponse }
        return text
    }

    private static func decode<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = candidate.firstIndex(of: "{"), let end = candidate.lastIndex(of: "}") {
            candidate = String(candidate[start...end])
        }
        return candidate.data(using: .utf8).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    // MARK: - 指示文

    /// レベル制約を英語一文にする。
    static func levelSpec(_ level: ReadingLevel) -> String {
        guard level != .original else {
            return "original — keep the wording verbatim; do NOT simplify; advancedTerms must be empty"
        }
        let p = level.parameters
        let clauses = p.allowsSubordinateClauses ? "subordinate clauses allowed" : "simple sentences only, avoid subordinate clauses"
        return "vocabulary within the top \(p.vocabularyRankCap) most frequent words; sentences about \(p.maxSentenceLength) words or fewer; \(clauses)"
    }

    static func instruction(nativeLanguageCode: String) -> String {
        """
        You rewrite articles for language learners. You will receive SEVERAL articles, each with an INDEX, \
        a target level, and its language. For EACH article:
        - Rewrite in the article's own language (do not translate), preserving meaning, facts, names, numbers.
        - Apply the item's level constraints.
        - Divide into 3 or 4 coherent segments in reading order.
        - For each segment provide `imagePrompt`: a detailed description of an illustration that clearly \
        EXPLAINS what the segment is about, so a learner can understand the paragraph's content just by \
        looking at the picture. Describe ONE coherent, concrete scene: the specific subjects (people, animals, \
        or objects), what they are doing (actions), where it happens (setting/place), and how they relate — \
        enough visual detail that the image retells the segment's key point. Prefer concrete, depictable nouns \
        and actions over moods. 20 to 35 English words. No text, letters, labels, charts, or abstract \
        symbols/metaphors.
        - If you must keep a word above the level, leave it in `text` and list it (once) in that segment's \
        `advancedTerms` with a translation in the learner's native language (\(nativeLanguageCode)).
        - The `text` field must be natural prose only — never insert tags, angle brackets, or markup.
        Return ONLY one JSON object of exactly this shape, with one entry per input article (match by index):
        {"articles":[{"index":1,"segments":[{"text":"...","advancedTerms":[{"surface":"...","translation":"..."}],"imagePrompt":"..."}]}]}
        """
    }

    static func userText(items: [RewriteBatchItem]) -> String {
        var lines: [String] = []
        for (i, item) in items.enumerated() {
            lines.append("[\(i + 1)] Level: \(levelSpec(item.level)) — Language: \(item.languageCode)")
            lines.append("Article: \(item.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Codable

private struct GenerateRequest: Encodable {
    struct Part: Encodable { let text: String }
    struct Content: Encodable { let parts: [Part] }
    struct Config: Encodable {
        let responseMimeType: String
        let temperature: Double
    }
    let systemInstruction: Content
    let contents: [Content]
    let generationConfig: Config
}

private struct GenerateResponse: Decodable {
    struct Candidate: Decodable { let content: Content? }
    struct Content: Decodable { let parts: [Part]? }
    struct Part: Decodable { let text: String? }
    let candidates: [Candidate]?
}

private struct BatchOutput: Decodable {
    struct Segment: Decodable {
        let text: String
        let advancedTerms: [Term]?
        let imagePrompt: String?
    }
    struct Term: Decodable { let surface: String; let translation: String }
    struct Article: Decodable {
        let index: Int?
        let segments: [Segment]?
    }
    let articles: [Article]
}

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
