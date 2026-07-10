import Foundation
import FoundationModels
import NaturalLanguage
import os

/// FoundationModels で書き換えるときの構造化出力（guided generation）。
/// ドメインの `RewrittenSegment` とは別に、モデル出力専用の型を用意する。
@Generable
struct RewriteOutput {
    @Guide(description: "The rewritten passage using only allowed vocabulary. Preserve the original meaning.")
    var text: String

    @Guide(description: "Words that had to be used above the target level, each with a translation. Empty if none.")
    var advancedTerms: [TermOutput]

    @Guide(description: "A detailed description of an illustration that clearly explains what this passage is about, so a learner understands the paragraph just by looking. Describe ONE concrete scene: the specific subjects (people, animals, objects), what they are doing, where it happens, and how they relate — enough detail that the image retells the passage's key point. 20 to 35 English words, concrete depictable nouns and actions, no text or letters, no abstract symbols.")
    var imagePrompt: String
}

@Generable
struct TermOutput {
    @Guide(description: "The exact word or phrase as it appears in text")
    var surface: String

    @Guide(description: "Translation into the learner's native language")
    var translation: String
}

/// 記事本文を NLTokenizer で 3〜4 セグメントに分割し、各セグメントを FoundationModels で
/// レベルに合わせて書き換える。約 4096 トークン制約に備え、超過時はセグメントを二分割して再帰リトライ。
struct FoundationModelsRewriter: TextRewriting {
    private static let logger = Logger(subsystem: "com.mtkg.LearnLanguage", category: "Rewrite")

    /// 記事の書き換え（＝既存コンテンツの変換）向けに、ガードレールを緩めたモデルを使う。
    /// 既定のガードレールは良性の記事でも誤って拒否（refusal）することがあるため。
    private let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)

    func rewrite(
        text: String,
        level: ReadingLevel,
        languageCode: String,
        nativeLanguageCode: String
    ) async throws -> [RewrittenSegment] {
        // 段階1: 文分割 → 3〜4 塊に正規化（LLM を使わない）。
        // `languageCode` は学習対象（出力）言語であり元本文の言語とは限らないため、
        // 分割には本文から検出した言語を使う（検出できなければ対象言語で代用）。
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let sourceLanguage = recognizer.dominantLanguage?.rawValue ?? languageCode
        let sentences = Self.splitSentences(text, languageCode: sourceLanguage)
        let groups = Self.groupIntoSegments(sentences)

        // オリジナルは書き換えず、分割結果をそのまま各セグメントに割り当てる。
        if case .original = level {
            return groups.enumerated().map { index, group in
                RewrittenSegment(order: index, text: group.joined(separator: " "), advancedTerms: [])
            }
        }

        // 段階2: 各セグメントを個別に書き換え。
        let instructions = level.rewriteInstructions(
            languageCode: languageCode,
            nativeLanguageCode: nativeLanguageCode
        )
        var results: [RewrittenSegment] = []
        for (index, group) in groups.enumerated() {
            let segmentText = group.joined(separator: " ")
            let rewritten = await rewriteSegment(
                segmentText,
                order: index,
                instructions: instructions,
                languageCode: languageCode
            )
            results.append(rewritten)
        }
        return results
    }

    // MARK: - セグメント書き換え（再帰リトライ付き）

    /// 分割再試行の最大深さ（1 セグメントを最大 2^depth 片まで分割）。
    private static let maxRetryDepth = 1

    /// セグメントを書き換える。失敗しても throw せず、回復不能なら元の文をそのまま返す
    /// （1 セグメントの拒否＝guardrail 違反などで記事全体を失敗させないため）。
    private func rewriteSegment(
        _ segmentText: String,
        order: Int,
        instructions: String,
        languageCode: String,
        depth: Int = 0
    ) async -> RewrittenSegment {
        let session = LanguageModelSession(model: model, instructions: instructions)
        let options = GenerationOptions(temperature: 0.3)
        do {
            let response = try await session.respond(
                to: "Rewrite this passage:\n\n\(segmentText)",
                generating: RewriteOutput.self,
                options: options
            )
            let output = response.content
            // モデルがスキーマ/指示文をそのまま返す退化出力を検出したら、書き換え失敗として扱う。
            if Self.looksDegenerate(output.text) {
                Self.logger.error("degenerate rewrite output; falling back to original")
                return RewrittenSegment(order: order, text: segmentText, advancedTerms: [], imagePrompt: "")
            }
            return RewrittenSegment(
                order: order,
                text: output.text,
                advancedTerms: output.advancedTerms.map {
                    AdvancedTerm(surface: $0.surface, translation: $0.translation)
                },
                imagePrompt: output.imagePrompt
            )
        } catch {
            Self.logger.error("rewrite failed (depth \(depth)): \(String(describing: error), privacy: .public)")
            // コンテキスト超過（約 4096 トークン）対策として、まず二分割して各々を書き換える。
            if depth < Self.maxRetryDepth,
               let (first, second) = Self.bisect(segmentText, languageCode: languageCode) {
                let a = await rewriteSegment(first, order: order, instructions: instructions,
                                             languageCode: languageCode, depth: depth + 1)
                let b = await rewriteSegment(second, order: order, instructions: instructions,
                                             languageCode: languageCode, depth: depth + 1)
                return RewrittenSegment(
                    order: order,
                    text: a.text + " " + b.text,
                    advancedTerms: a.advancedTerms + b.advancedTerms,
                    imagePrompt: a.imagePrompt
                )
            }
            // 回復不能（拒否/guardrail など）: 書き換えず元の文をそのまま使う。
            return RewrittenSegment(order: order, text: segmentText, advancedTerms: [], imagePrompt: "")
        }
    }

    /// テキストを文境界でほぼ半分に二分割する。2 文未満で分割不能なら nil。
    static func bisect(_ text: String, languageCode: String) -> (String, String)? {
        let sentences = splitSentences(text, languageCode: languageCode)
        guard sentences.count > 1 else { return nil }
        let mid = sentences.count / 2
        let first = sentences[..<mid].joined(separator: " ")
        let second = sentences[mid...].joined(separator: " ")
        return (first, second)
    }

    /// モデルが記事本文を書き換えず、guided generation のスキーマ/指示文をそのまま
    /// 返してしまった退化出力かどうかを判定する（薄い/混乱した入力で起きやすい）。
    static func looksDegenerate(_ text: String) -> Bool {
        let markers = [
            "Respond using compact JSON",
            "Adhere to the following format",
            "The rewritten passage using only allowed vocabulary",
            "\"advancedTerms\"",
            "\"imagePrompt\"",
            "\"properties\"",
        ]
        return markers.contains { text.contains($0) }
    }

    // MARK: - 文分割・グルーピング（純ロジック、テスト対象）

    /// NLTokenizer による言語指定の文分割。
    static func splitSentences(_ text: String, languageCode: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.setLanguage(NLLanguage(languageCode))
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            return true
        }
        return sentences
    }

    /// 文の配列を、読みの流れを保ったまま連続した最大 4 グループへ均等分割する。
    static func groupIntoSegments(_ sentences: [String], maxSegments: Int = 4) -> [[String]] {
        guard !sentences.isEmpty else { return [] }
        let count = min(maxSegments, sentences.count)
        let base = sentences.count / count
        let remainder = sentences.count % count
        var groups: [[String]] = []
        var index = 0
        for i in 0..<count {
            let size = base + (i < remainder ? 1 : 0)
            groups.append(Array(sentences[index..<index + size]))
            index += size
        }
        return groups
    }
}
