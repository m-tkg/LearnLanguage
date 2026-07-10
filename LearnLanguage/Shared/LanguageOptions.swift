import Foundation

/// アプリで選択できる言語の一覧（母語・学習対象言語の両ピッカーで共用）。
/// 表示名はその言語自身の名称で固定（ネイティブ名。UI 言語によらず同じ表記にする）。
enum LanguageOptions {
    static let all: [(code: String, name: String)] = [
        ("en", "English"),
        ("ja", "日本語"),
        ("zh", "中文"),
        ("ko", "한국어"),
        ("es", "Español"),
        ("fr", "Français"),
        ("de", "Deutsch"),
    ]

    /// コードからネイティブ名を返す（一覧に無ければコードをそのまま）。
    static func name(for code: String) -> String {
        all.first(where: { $0.code == code })?.name ?? code
    }
}
