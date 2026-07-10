import Foundation

/// この端末（インストール）を識別する ID。初回アクセス時に生成して UserDefaults に保存する。
/// 記事の生成オーナーシップ（どの端末がキュー処理を担当するか）の判定に使う。
/// - Note: `SettingsCloudSync` の同期対象キーには**含めない**こと（端末ごとに異なる値であることが本質）。
enum DeviceID {
    private static let key = "deviceInstanceID"

    static let current: String = {
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }()
}
