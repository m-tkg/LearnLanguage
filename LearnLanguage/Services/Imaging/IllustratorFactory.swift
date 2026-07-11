import Foundation

/// 画像生成プロバイダの選択肢。設定（AppStorage）に保存する生値も担う。
enum ImageProvider: String, CaseIterable, Identifiable {
    case pollinations   // 無料・キー不要（既定）
    case cloudflare     // Cloudflare Workers AI（無料枠が広い・Account ID + API トークンが必要）
    case gemini         // 要 API キー（無料枠は画像生成が 429 になりやすく実質有料）

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pollinations: return "無料（Pollinations）"
        case .cloudflare: return "Cloudflare（無料枠・要設定）"
        case .gemini: return "Gemini（要APIキー）"
        }
    }
}

/// Cloudflare Workers AI の画像生成モデルの選択肢。設定（AppStorage）に保存する生値も担う。
enum CloudflareImageModel: String, CaseIterable, Identifiable {
    /// beta 提供中は $0.00 で Neurons（無料枠）を消費しない。
    case sdxlLightning = "@cf/bytedance/stable-diffusion-xl-lightning"
    /// 高品質だが約 172.8 Neurons/枚（無料枠 10,000 Neurons/日 ≒ 約57枚）。
    case fluxSchnell = "@cf/black-forest-labs/flux-1-schnell"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sdxlLightning: return "SDXL Lightning（無料枠を消費しない）"
        case .fluxSchnell: return "FLUX schnell（高品質・1日約57枚）"
        }
    }

    static let defaultsKey = "cloudflareImageModel"

    /// 設定で選ばれているモデル。未設定なら無料枠を消費しない SDXL Lightning。
    static var current: CloudflareImageModel {
        CloudflareImageModel(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .sdxlLightning
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
        case .cloudflare:
            return CloudflareIllustrator()
        case .pollinations, .none:
            return PollinationsIllustrator()
        }
    }
}
