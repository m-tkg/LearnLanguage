import Foundation

/// Home 画面の入力状態と URL 検証。生成の実行はキュー（GenerationQueue）に委ねる。
@MainActor
@Observable
final class HomeViewModel {
    var urlString: String = ""
    var errorMessage: String?

    var canCreate: Bool {
        URL(string: urlString.trimmingCharacters(in: .whitespaces))?.scheme != nil
    }

    /// URL を検証して返す。無効なら nil を返しエラー文言をセットする。
    func validatedURL() -> URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), url.scheme != nil else {
            errorMessage = "有効な URL を入力してください。"
            return nil
        }
        errorMessage = nil
        return url
    }

    /// 追加後、すぐ次を入力できるよう入力欄をクリアする（レベルは @AppStorage 側で維持）。
    func reset() {
        urlString = ""
        errorMessage = nil
    }
}
