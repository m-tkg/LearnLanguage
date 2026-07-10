import Foundation

/// シェアシートから受け取った「URL＋難易度」をメインアプリへ受け渡す 1 件分。
struct PendingShare: Codable {
    let url: String
    /// `ReadingLevel.storageValue`（0=オリジナル, 1=初級, 2=中級, 3=上級）。
    let levelStorageValue: Int
}

/// シェアシート（Share Extension）から受け取った共有を、App Group 経由でメインアプリへ受け渡す受信箱。
/// Extension は `append` で積み、メインアプリは起動/前面化時に `drain` で取り出してキューへ入れる。
enum SharedInbox {
    /// メインアプリと Extension で共有する App Group。
    static let appGroupID = "group.com.mtkg.LearnLanguage"
    private static let key = "pendingShares"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroupID) }

    /// 共有された URL と選択された難易度を受信箱に追加する（Extension 側）。
    static func append(url: URL, levelStorageValue: Int) {
        guard let defaults else { return }
        var shares = load()
        shares.append(PendingShare(url: url.absoluteString, levelStorageValue: levelStorageValue))
        if let data = try? JSONEncoder().encode(shares) {
            defaults.set(data, forKey: key)
        }
    }

    /// 受信箱の共有を全て取り出して空にする（メインアプリ側）。
    static func drain() -> [PendingShare] {
        let shares = load()
        defaults?.removeObject(forKey: key)
        return shares
    }

    private static func load() -> [PendingShare] {
        guard let defaults, let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([PendingShare].self, from: data)) ?? []
    }
}
