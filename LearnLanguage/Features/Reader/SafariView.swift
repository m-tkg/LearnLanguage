import SwiftUI
import SafariServices

/// アプリ内ブラウザ（SFSafariViewController）の SwiftUI ラッパ。
/// リーダーモード・コンテンツブロッカー・自動入力など Safari の機能をそのまま使える。
/// - Note: SFSafariViewController は http/https の URL のみ受け付ける（それ以外は表示側で弾くこと）。
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
