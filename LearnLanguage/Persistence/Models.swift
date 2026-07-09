import Foundation
import SwiftData

/// セグメントのイラスト生成状態。画像はベストエフォートで生成されるため状態を保持する。
enum SegmentImageState: String, Codable, Sendable {
    case pending      // 未着手
    case generating   // 生成中
    case ready        // 生成完了（imageData あり）
    case failed       // 生成失敗（プレースホルダ表示 + リトライ対象）
}

/// 記事（教材）の生成状態。キューで順次処理される。
enum ArticleStatus: String, Codable, Sendable {
    case queued       // 待機中（キュー投入済み・未着手）
    case processing   // 取得/書き換え/イラスト生成中
    case failed       // 生成失敗
    case completed    // 完成
}

/// 1 本の学習記事。元 URL・元本文・レベル・お気に入りなどのメタと、順序付きセグメントを持つ。
@Model
final class LearningArticle {
    /// アプリ内で安定して参照するための ID（永続 ID とは別に保持）。
    var id: UUID
    /// 元記事の URL。
    var sourceURL: URL
    /// 記事タイトル（抽出結果 or フォールバック）。
    var title: String
    /// 学習対象言語（BCP-47。例: "en", "fr"）。多言語対応の要。
    var languageCode: String
    /// 学習者の母語 = 用語集の訳語ターゲット（BCP-47。初期値 "ja"）。
    var translationLanguageCode: String
    /// 目標レベル。1（初級）〜10（上級）。`isOriginal` が true の場合は未使用。
    var targetLevel: Int
    /// 「オリジナル」指定（書き換えをスキップし元本文を分割のみ）。
    var isOriginal: Bool
    /// 抽出した元本文（プレーンテキスト）。
    var originalText: String
    /// 作成日時（履歴の並び順に使用）。
    var createdAt: Date
    /// お気に入りフラグ。
    var isFavorite: Bool
    /// 生成状態の生値（`status` 経由で読み書き）。既定は完了（既存データ互換）。
    var statusRaw: String = ArticleStatus.completed.rawValue
    /// 生成失敗時の理由。
    var failureReason: String? = nil
    /// 一覧での手動並び替え順（小さいほど上に表示）。既定 0。
    var sortIndex: Int = 0
    /// この記事専用の読み上げ速度（nil のときは設定のデフォルト速度を使う）。
    var speechRate: Double? = nil

    /// 型付きの生成状態アクセサ。
    var status: ArticleStatus {
        get { ArticleStatus(rawValue: statusRaw) ?? .completed }
        set { statusRaw = newValue.rawValue }
    }

    @Relationship(deleteRule: .cascade, inverse: \ArticleSegment.article)
    var segments: [ArticleSegment]

    /// 生成処理の進捗ログ（長押しで開くログ画面に時系列表示する）。
    @Relationship(deleteRule: .cascade, inverse: \ArticleLogEntry.article)
    var logs: [ArticleLogEntry] = []

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        title: String,
        languageCode: String,
        translationLanguageCode: String,
        targetLevel: Int,
        isOriginal: Bool = false,
        originalText: String = "",
        createdAt: Date = .now,
        isFavorite: Bool = false,
        segments: [ArticleSegment] = []
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.title = title
        self.languageCode = languageCode
        self.translationLanguageCode = translationLanguageCode
        self.targetLevel = targetLevel
        self.isOriginal = isOriginal
        self.originalText = originalText
        self.createdAt = createdAt
        self.isFavorite = isFavorite
        self.segments = segments
    }
}

/// 記事を 3〜4 個に分割した学習の 1 塊。書き換え済み本文・イラスト・用語集を持つ。
@Model
final class ArticleSegment {
    /// 表示順（0 始まり）。
    var order: Int
    /// レベルに合わせて書き換えた本文（オリジナル指定時は元本文の一部）。
    var rewrittenText: String
    /// Image Playground 用の短い視覚的プロンプト（具体名詞中心の一文）。無ければ本文から代替。
    var imagePrompt: String? = nil
    /// イラスト画像データ。大きめ BLOB のため外部ストレージに逃がし、削除連動を SwiftData に任せる。
    @Attribute(.externalStorage) var imageData: Data?
    /// イラスト生成状態の生値（`imageState` 経由で読み書きする）。
    var imageStateRaw: String
    /// イラスト生成に失敗したときの理由（プレースホルダに表示。成功時は nil）。
    var imageFailureReason: String? = nil

    @Relationship(deleteRule: .cascade, inverse: \GlossaryTerm.segment)
    var glossary: [GlossaryTerm]

    /// 逆参照。cascade 削除の親。
    var article: LearningArticle?

    /// 型付きの生成状態アクセサ。
    var imageState: SegmentImageState {
        get { SegmentImageState(rawValue: imageStateRaw) ?? .pending }
        set { imageStateRaw = newValue.rawValue }
    }

    init(
        order: Int,
        rewrittenText: String,
        imagePrompt: String? = nil,
        imageData: Data? = nil,
        imageState: SegmentImageState = .pending,
        glossary: [GlossaryTerm] = []
    ) {
        self.order = order
        self.rewrittenText = rewrittenText
        self.imagePrompt = imagePrompt
        self.imageData = imageData
        self.imageStateRaw = imageState.rawValue
        self.glossary = glossary
    }
}

/// 生成処理の進捗ログ 1 行。記事の長押しで開くログ画面にリアルタイム表示する。
/// 表示時に言語へ追従できるよう、確定文ではなく**ローカライズ用フォーマットキー＋引数**で保存する。
@Model
final class ArticleLogEntry {
    /// 記録時刻。
    var timestamp: Date
    /// ローカライズ用のフォーマットキー（xcstrings のキー。引数は %@ で埋める）。既定は空（旧データ互換）。
    var messageKey: String = ""
    /// フォーマットに差し込む引数（文字列化済み）。
    var messageArgs: [String] = []
    /// エラー行か（画面で赤表示）。
    var isError: Bool
    /// 所属記事の ID（`@Query` のフィルタ用に直接保持し、述語を単純化する）。
    var articleID: UUID

    /// 逆参照。cascade 削除の親。
    var article: LearningArticle?

    init(timestamp: Date = .now, messageKey: String, messageArgs: [String] = [], isError: Bool = false, articleID: UUID) {
        self.timestamp = timestamp
        self.messageKey = messageKey
        self.messageArgs = messageArgs
        self.isError = isError
        self.articleID = articleID
    }

    /// 現在の言語でローカライズしたメッセージ（表示用）。
    var localizedMessage: String {
        let format = String(localized: String.LocalizationValue(messageKey))
        guard !messageArgs.isEmpty else { return format }
        return String(format: format, arguments: messageArgs.map { $0 as CVarArg })
    }
}

/// レベルを超えてやむを得ず使った語と、その母語訳。本文中では該当語を強調表示する。
@Model
final class GlossaryTerm {
    /// 本文中に現れる語形（強調の検索キー）。
    var surface: String
    /// 見出し語（屈折言語での一致に備える。任意）。
    var lemma: String?
    /// 母語訳。
    var translation: String

    /// 逆参照。
    var segment: ArticleSegment?

    init(surface: String, lemma: String? = nil, translation: String) {
        self.surface = surface
        self.lemma = lemma
        self.translation = translation
    }
}
