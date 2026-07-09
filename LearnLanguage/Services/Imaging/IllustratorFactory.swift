import Foundation

/// 画像生成プロバイダの選択肢。設定（AppStorage）に保存する生値も担う。
enum ImageProvider: String, CaseIterable, Identifiable {
    case pollinations   // 無料・キー不要（既定）
    case gemini         // 要 API キー（無料枠は画像生成が 429 になりやすく実質有料）

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pollinations: return "無料（Pollinations）"
        case .gemini: return "Gemini（要APIキー）"
        }
    }
}

/// AppStorage の設定に従って実サービスのイラスト生成器を返す。
/// View 以外からも読むため UserDefaults を直接参照する。
enum IllustratorFactory {
    static let providerDefaultsKey = "imageProvider"

    static func live() -> any IllustrationGenerating {
        let raw = UserDefaults.standard.string(forKey: providerDefaultsKey)
        switch ImageProvider(rawValue: raw ?? "") {
        case .gemini:
            return GeminiIllustrator()
        case .pollinations, .none:
            return PollinationsIllustrator()
        }
    }
}
