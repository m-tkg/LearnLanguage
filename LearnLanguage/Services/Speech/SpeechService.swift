import Foundation
import AVFoundation

/// AVSpeechSynthesizer による読み上げ。記事の言語に対応した音声を選び、速度を調整できる。
/// サイレントスイッチを無視して再生し、読み上げ中かどうかを `isSpeaking` で公開する。
@MainActor
@Observable
final class SpeechService: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()

    /// 現在読み上げ中か（ボタン表示の切り替えに使う）。
    private(set) var isSpeaking = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, languageCode: String, rate: Float) {
        Self.activatePlaybackSession()
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestVoice(for: languageCode)
        utterance.rate = Self.utteranceRate(for: rate)
        utterance.prefersAssistiveTechnologySettings = false
        synthesizer.speak(utterance)
    }

    /// 指定言語で、インストール済みの最高品質（Premium > Enhanced > Default）の声を選ぶ。
    /// Premium/Enhanced の声は「設定 → アクセシビリティ → 読み上げコンテンツ → 声」から
    /// ダウンロードすると、より滑らかな発音になる。
    nonisolated static func bestVoice(for languageCode: String) -> AVSpeechSynthesisVoice? {
        let base = languageCode.split(separator: "-").first.map(String.init)?.lowercased()
            ?? languageCode.lowercased()
        let matching = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.lowercased().hasPrefix(base)
        }
        guard !matching.isEmpty else { return AVSpeechSynthesisVoice(language: languageCode) }

        // 完全一致の言語を優先し、その中で品質が高い声を選ぶ。
        return matching.max { lhs, rhs in
            let lhsExact = lhs.language.caseInsensitiveCompare(languageCode) == .orderedSame ? 1 : 0
            let rhsExact = rhs.language.caseInsensitiveCompare(languageCode) == .orderedSame ? 1 : 0
            if lhsExact != rhsExact { return lhsExact < rhsExact }
            return quality(lhs) < quality(rhs)
        }
    }

    private nonisolated static func quality(_ voice: AVSpeechSynthesisVoice) -> Int {
        switch voice.quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// サイレント（消音）スイッチが ON でも再生されるよう、再生用カテゴリを有効化する。
    private static func activatePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true)
    }

    /// 0.0...1.0 の速度指定を AVSpeechUtterance の rate 範囲へ線形写像する（0.5 で中間）。
    nonisolated static func utteranceRate(for normalized: Float) -> Float {
        let clamped = max(0, min(1, normalized))
        let minimum = AVSpeechUtteranceMinimumSpeechRate
        let maximum = AVSpeechUtteranceMaximumSpeechRate
        return minimum + (maximum - minimum) * clamped
    }

    // MARK: - AVSpeechSynthesizerDelegate（コールバックは非隔離のため MainActor へホップ）

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = true }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
