import Foundation

/// 設定値の入れ物の抽象（UserDefaults / NSUbiquitousKeyValueStore / テスト用フェイク）。
protocol SettingsKeyValueStore: AnyObject {
    func settingsValue(forKey key: String) -> Any?
    func setSettingsValue(_ value: Any?, forKey key: String)
}

extension UserDefaults: SettingsKeyValueStore {
    func settingsValue(forKey key: String) -> Any? { object(forKey: key) }
    func setSettingsValue(_ value: Any?, forKey key: String) { set(value, forKey: key) }
}

extension NSUbiquitousKeyValueStore: SettingsKeyValueStore {
    func settingsValue(forKey key: String) -> Any? { object(forKey: key) }
    func setSettingsValue(_ value: Any?, forKey key: String) { set(value, forKey: key) }
}

/// 一般設定（母語・既定レベル・読み上げ速度・プロバイダ選択等）を iCloud KVS 経由で端末間同期する。
/// `@AppStorage`（UserDefaults）はそのまま生かし、UserDefaults ⇄ KVS を双方向ミラーリングする。
/// - 衝突時（両方に値があり異なる）は**クラウド優先**（KVS の慣例。後から来た端末が既存設定を引き継ぐ）。
/// - 同じ値は書き込まないため、変更通知が循環しない。
/// - API キー類はここでは扱わない（`KeychainStore` の iCloud キーチェーン同期に任せる）。
@MainActor
final class SettingsCloudSync {
    /// 同期対象のキー一覧。**設定項目を追加したらここにも足すこと**（忘れるとその項目だけ同期されない）。
    static let syncedKeys = [
        "nativeLanguageCode",
        "targetLanguageCode",
        "speechRate",
        "defaultReadingLevel",
        RewriterFactory.providerDefaultsKey,
        IllustratorFactory.providerDefaultsKey,
        GeminiModel.defaultsKey,
        CloudflareImageModel.defaultsKey,
    ]

    private let local: SettingsKeyValueStore
    private let cloud: SettingsKeyValueStore
    private let keys: [String]
    private var observers: [NSObjectProtocol] = []

    init(
        local: SettingsKeyValueStore = UserDefaults.standard,
        cloud: SettingsKeyValueStore = NSUbiquitousKeyValueStore.default,
        keys: [String] = SettingsCloudSync.syncedKeys
    ) {
        self.local = local
        self.cloud = cloud
        self.keys = keys
    }

    // App が @State で保持しアプリと同寿命のため、オブザーバの解除（deinit）は設けない。

    /// 同期を開始する（起動時に1回）。初回はクラウド→ローカルの順で揃え、以後は変更を双方向に流す。
    func start() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud as? NSUbiquitousKeyValueStore,
            queue: .main
        ) { [weak self] _ in
            // queue: .main 指定なのでメインスレッド上で呼ばれる。
            MainActor.assumeIsolated { self?.pullFromCloud() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: local as? UserDefaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushToCloud() }
        })
        (cloud as? NSUbiquitousKeyValueStore)?.synchronize()
        pullFromCloud()
        pushToCloud()
    }

    /// クラウドの値をローカルへ取り込む（異なる値のみ。クラウドに無いキーは触らない）。
    func pullFromCloud() {
        for key in keys {
            guard let cloudValue = cloud.settingsValue(forKey: key) else { continue }
            if !Self.isEqual(cloudValue, local.settingsValue(forKey: key)) {
                local.setSettingsValue(cloudValue, forKey: key)
            }
        }
    }

    /// ローカルの値をクラウドへ上げる（異なる値のみ。ローカルに無いキーは触らない）。
    func pushToCloud() {
        for key in keys {
            guard let localValue = local.settingsValue(forKey: key) else { continue }
            if !Self.isEqual(localValue, cloud.settingsValue(forKey: key)) {
                cloud.setSettingsValue(localValue, forKey: key)
            }
        }
    }

    private static func isEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (let l as NSObject, let r as NSObject): return l.isEqual(r)
        default: return false
        }
    }
}
