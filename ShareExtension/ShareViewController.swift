import UIKit
import UniformTypeIdentifiers

/// 共有された URL（または URL を含むテキスト）について難易度を選ばせ、App Group の受信箱に積む。
/// キャンセルもできる。実際の記事生成はメインアプリが起動/前面化時に受信箱を drain して行う。
final class ShareViewController: UIViewController {
    private var pendingURLs: [URL] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.2)
        Task { await start() }
    }

    private func start() async {
        pendingURLs = await collectURLs()
        guard !pendingURLs.isEmpty else {
            await finish(message: String(localized: "記事を追加できませんでした"))
            return
        }
        presentLevelSheet()
    }

    /// 難易度を選ばせるアクションシート。各難易度で保存、キャンセルで何もせず閉じる。
    private func presentLevelSheet() {
        let alert = UIAlertController(
            title: String(localized: "難易度を選択"),
            message: nil,
            preferredStyle: .actionSheet
        )
        for level in ReadingLevel.allCases {
            let title = String(localized: String.LocalizationValue(level.displayName))
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.confirm(level: level)
            })
        }
        alert.addAction(UIAlertAction(title: String(localized: "キャンセル"), style: .cancel) { [weak self] _ in
            self?.extensionContext?.cancelRequest(withError: NSError(domain: "ShareExtension", code: NSUserCancelledError))
        })
        // iPad ではポップオーバー表示のためアンカーが必要。
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        present(alert, animated: true)
    }

    /// 選ばれた難易度で受信箱へ積み、確認を出してから閉じる。
    private func confirm(level: ReadingLevel) {
        for url in pendingURLs {
            SharedInbox.append(url: url, levelStorageValue: level.storageValue)
        }
        Task { await finish(message: String(localized: "記事を追加しました")) }
    }

    /// トーストを出して少し待ってから Extension を閉じる。
    private func finish(message: String) async {
        showToast(message)
        try? await Task.sleep(for: .seconds(1.2))
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// 共有アイテムから URL を集める。
    private func collectURLs() async -> [URL] {
        var urls: [URL] = []
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        for item in items {
            for provider in item.attachments ?? [] {
                if let url = await extractURL(from: provider) { urls.append(url) }
            }
        }
        return urls
    }

    /// プロバイダから URL を取り出す。URL 型を優先し、無ければテキスト中の最初の URL を拾う。
    private func extractURL(from provider: NSItemProvider) async -> URL? {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let item = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier),
           let url = item as? URL {
            return url
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier),
           let text = item as? String {
            return Self.firstURL(in: text)
        }
        return nil
    }

    /// テキスト中に含まれる最初の URL を返す。
    static func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.firstMatch(in: text, range: range)?.url
    }

    /// 中央に自動で消えるトーストを表示する。
    private func showToast(_ text: String) {
        let container = UIView()
        container.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        container.layer.cornerRadius = 14
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .headline)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)
        view.addSubview(container)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            container.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.8),
        ])
    }
}
