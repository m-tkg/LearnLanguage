import Foundation
import AVFoundation

/// アプリで選択できる言語の一覧（母語・学習対象言語の両ピッカーで共用）。
/// iOS に読み上げ音声が存在する全言語を動的に列挙する（読み上げできることが教材の実質的な下限）。
/// 表示名はその言語自身の名称（ネイティブ名。UI 言語によらず同じ表記）。
enum LanguageOptions {
    /// よく使う言語（一覧の先頭に固定表示する）。
    private static let featured = ["en", "ja", "zh", "ko", "es", "fr", "de"]

    static let all: [(code: String, name: String)] = {
        // 読み上げ音声がインストールされている言語のベースコード（"en-US" → "en"）を集める。
        let voiceCodes = Set(AVSpeechSynthesisVoice.speechVoices().compactMap { voice in
            voice.language.split(separator: "-").first.map(String.init)?.lowercased()
        })
        // 音声一覧が取れない環境（まれ）でも主要言語は必ず出す。
        let codes = voiceCodes.isEmpty ? Set(featured) : voiceCodes.union(featured)

        let others = codes.subtracting(featured)
            .map { (code: $0, name: nativeName(for: $0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let head = featured.filter(codes.contains).map { (code: $0, name: nativeName(for: $0)) }
        return head + others
    }()

    /// コードからネイティブ名を返す（解決できなければコードをそのまま）。
    static func name(for code: String) -> String {
        all.first(where: { $0.code == code })?.name ?? nativeName(for: code)
    }

    /// 言語コードをその言語自身での名称にする（例: "fr" → "français" → 先頭を大文字化）。
    private static func nativeName(for code: String) -> String {
        guard let name = Locale(identifier: code).localizedString(forLanguageCode: code) else {
            return code
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
