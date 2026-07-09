import Foundation
import FoundationModels

/// オンデバイス AI（LLM）の可用性。非対応時はビューア専用に degrade する判断に使う。
///
/// イラスト生成は対話的な `imagePlaygroundSheet`（学習画面）に委ねており、その可否は
/// SwiftUI の `\.supportsImagePlayground` 環境値で View 側が判定するため、ここでは扱わない。
struct IntelligenceAvailability: Sendable, Equatable {
    enum LLMStatus: Sendable, Equatable {
        case available
        case deviceNotEligible       // 非対応端末 → ビューア専用に degrade
        case notEnabled              // Apple Intelligence 未有効 → 設定導線案内
        case modelNotReady           // モデル DL 未完了 → リトライ待ち
        case unknown
    }

    var llm: LLMStatus

    /// 新規教材を生成できるか（LLM が使えることが必須）。
    var canGenerate: Bool { llm == .available }
}

protocol IntelligenceAvailabilityProviding: Sendable {
    func current() async -> IntelligenceAvailability
}

/// FoundationModels の可用性を集約する具象実装。
struct IntelligenceAvailabilityService: IntelligenceAvailabilityProviding {
    func current() async -> IntelligenceAvailability {
        IntelligenceAvailability(llm: Self.llmStatus())
    }

    private static func llmStatus() -> IntelligenceAvailability.LLMStatus {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .deviceNotEligible
            case .appleIntelligenceNotEnabled:
                return .notEnabled
            case .modelNotReady:
                return .modelNotReady
            @unknown default:
                return .unknown
            }
        }
    }
}
