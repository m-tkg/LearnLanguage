import Foundation

/// 使用する Gemini モデル。1日あたりの無料枠はモデルごとに別枠なので、切り替えで回避できる。
enum GeminiModel: String, CaseIterable, Identifiable {
    case flashLite = "gemini-2.5-flash-lite"
    case flash = "gemini-2.5-flash"
    case pro = "gemini-2.5-pro"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .flashLite: return "Flash-Lite（軽量・無料枠が広め）"
        case .flash: return "Flash（標準・高品質・無料枠は狭め）"
        case .pro: return "Pro（最高品質・有料）"
        }
    }

    static let defaultsKey = "geminiModel"

    /// 設定で選ばれているモデル ID。未設定なら Flash-Lite。
    static var current: String {
        UserDefaults.standard.string(forKey: defaultsKey) ?? GeminiModel.flashLite.rawValue
    }
}

/// 書き換えプロバイダの選択肢。
enum RewriteProvider: String, CaseIterable, Identifiable {
    case gemini      // Gemini API（要 API キー・テキストは無料枠）
    case onDevice    // Apple FoundationModels（オンデバイス）

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemini: return "Gemini（要APIキー）"
        case .onDevice: return "オンデバイス（Apple）"
        }
    }
}

/// AppStorage の設定に従って実サービスの書き換え器を返す。
enum RewriterFactory {
    static let providerDefaultsKey = "rewriteProvider"

    static func live() -> any TextRewriting {
        if isGeminiSelected {
            return GeminiRewriter(model: GeminiModel.current)
        }
        return FoundationModelsRewriter()
    }

    /// Gemini 選択＋キーありのとき、複数記事を1リクエストでまとめる書き換え器を返す。それ以外は nil。
    static func liveBatchRewriter() -> GeminiRewriter? {
        isGeminiSelected ? GeminiRewriter(model: GeminiModel.current) : nil
    }

    /// Gemini を書き換えに使う設定で、かつ API キーがある。
    private static var isGeminiSelected: Bool {
        let raw = UserDefaults.standard.string(forKey: providerDefaultsKey)
        return RewriteProvider(rawValue: raw ?? RewriteProvider.gemini.rawValue) == .gemini
            && KeychainStore.exists(account: KeychainStore.geminiAPIKeyAccount)
    }
}
