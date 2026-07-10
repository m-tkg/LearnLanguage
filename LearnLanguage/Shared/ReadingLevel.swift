import Foundation

/// 読み書きレベル。初級・中級・上級・超上級の4段階と「オリジナル」。
/// レベルを言語非依存の数値パラメータ（許容語彙の頻度ランク上限・最大文長・文法許容度）で表し、
/// これを instructions に定量注入することで多言語でも同じロジックで駆動できる。
enum ReadingLevel: String, Sendable, Equatable, Hashable, CaseIterable, Identifiable {
    case beginner
    case intermediate
    case advanced
    case expert
    /// 書き換えなし（元本文を分割のみ）。
    case original

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .beginner: return "初級 (Beginner)"
        case .intermediate: return "中級 (Intermediate)"
        case .advanced: return "上級 (Advanced)"
        case .expert: return "超上級 (Expert)"
        case .original: return "オリジナル"
        }
    }

    /// 履歴一覧などで使う短いラベル。
    var shortName: String {
        switch self {
        case .beginner: return "初級"
        case .intermediate: return "中級"
        case .advanced: return "上級"
        case .expert: return "超上級"
        case .original: return "オリジナル"
        }
    }

    /// 永続化用の整数値。beginner=1, intermediate=2, advanced=3, expert=4, original=0。
    var storageValue: Int {
        switch self {
        case .beginner: return 1
        case .intermediate: return 2
        case .advanced: return 3
        case .expert: return 4
        case .original: return 0
        }
    }

    /// 永続化値からの復元。旧スキーマ（1〜10）の 4 以上は最上位の超上級に丸める。
    init(storageValue: Int, isOriginal: Bool) {
        if isOriginal || storageValue <= 0 {
            self = .original
        } else if storageValue == 1 {
            self = .beginner
        } else if storageValue == 2 {
            self = .intermediate
        } else if storageValue == 3 {
            self = .advanced
        } else {
            self = .expert
        }
    }

    /// レベルに対応する数値パラメータ。`original` は制約なし（最大値相当）。
    var parameters: LevelParameters {
        switch self {
        case .beginner:
            return LevelParameters(vocabularyRankCap: 800, maxSentenceLength: 10, allowsSubordinateClauses: false)
        case .intermediate:
            return LevelParameters(vocabularyRankCap: 2000, maxSentenceLength: 16, allowsSubordinateClauses: true)
        case .advanced:
            return LevelParameters(vocabularyRankCap: 5000, maxSentenceLength: 26, allowsSubordinateClauses: true)
        case .expert:
            // ネイティブ向け記事に近い難度（語彙はほぼ無制限に近く、長く複雑な文も許容）。
            return LevelParameters(vocabularyRankCap: 20000, maxSentenceLength: 40, allowsSubordinateClauses: true)
        case .original:
            return LevelParameters(vocabularyRankCap: .max, maxSentenceLength: .max, allowsSubordinateClauses: true)
        }
    }

    /// レベルを FoundationModels の instructions に落とすための指示文。
    /// `original` は書き換えないため空文字。母語（訳語ターゲット）はハードコードせず引数で受ける。
    func rewriteInstructions(languageCode: String, nativeLanguageCode: String) -> String {
        guard self != .original else { return "" }
        let p = parameters
        let clauses = p.allowsSubordinateClauses
            ? "Subordinate clauses are allowed when needed."
            : "Use only simple sentences; avoid subordinate clauses."
        return """
        Rewrite the passage in \(languageCode) for a language learner. If the passage is written in a \
        different language, translate it into \(languageCode) while rewriting.
        Preserve the original meaning. Use only vocabulary within the top \(p.vocabularyRankCap) \
        most frequent words of the language. Keep sentences to about \(p.maxSentenceLength) words or fewer. \
        \(clauses)
        If you must use a word above this level, keep it and add it to advancedTerms with a \
        translation in the learner's native language (\(nativeLanguageCode)).
        """
    }
}

/// レベルを言語非依存の数値パラメータで表す。
struct LevelParameters: Sendable, Equatable {
    /// 許容語彙の頻度ランク上限（上位 N 語まで使ってよい）。小さいほどやさしい。
    var vocabularyRankCap: Int
    /// 1 文あたりの目安最大語数。
    var maxSentenceLength: Int
    /// 従属節（関係詞・接続詞による複文）を許容するか。
    var allowsSubordinateClauses: Bool
}
