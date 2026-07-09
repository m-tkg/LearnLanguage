import Foundation
import os

/// Gemini API（gemini-2.5-flash-lite・テキストは無料枠）で、抽出済み本文をレベル別に書き換える。
/// tools を使わないため **JSON モード（responseMimeType: application/json）**が効き、構造化出力が安定する。
/// 複数記事を1リクエストにまとめる `rewriteBatch` を持つ（レート上限対策）。API キーは Keychain（BYOK）。
/// HTTP 送受信・リトライ・エラー分類は `GeminiClient` に委譲する。
struct GeminiRewriter: TextRewriting, BatchRewriting {
    private static let logger = Logger(subsystem: "com.mtkg.LearnLanguage", category: "Rewrite")

    var model: String = "gemini-2.5-flash-lite"
    var apiKey: @Sendable () -> String? = { KeychainStore.get(account: KeychainStore.geminiAPIKeyAccount) }

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
        guard let segments = results.first ?? nil, !segments.isEmpty else {
            throw GeminiClient.ClientError.emptyResponse
        }
        return segments
    }

    // MARK: - バッチ書き換え（複数記事を1リクエスト）

    func rewriteBatch(_ items: [RewriteBatchItem], nativeLanguageCode: String) async throws -> [[RewrittenSegment]?] {
        guard !items.isEmpty else { return [] }

        let instruction = Self.instruction(nativeLanguageCode: nativeLanguageCode)
        let userText = Self.userText(items: items)
        let body = GenerateRequest(
            systemInstruction: .init(parts: [.init(text: instruction)]),
            contents: [.init(parts: [.init(text: userText)])],
            generationConfig: .init(responseMimeType: "application/json", temperature: 0.3)
        )
        let data = try await GeminiClient.send(model: model, body: body, apiKey: apiKey())

        guard let jsonText = GeminiClient.firstText(from: data) else {
            throw GeminiClient.ClientError.emptyResponse
        }
        guard let batch = Self.decode(BatchOutput.self, from: jsonText) else {
            Self.logger.error("Gemini rewrite: unparseable response: \(jsonText.prefix(400), privacy: .public)")
            throw GeminiClient.ClientError.emptyResponse
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
