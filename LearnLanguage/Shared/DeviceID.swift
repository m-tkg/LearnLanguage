import Foundation
import UIKit

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

    /// 処理ログに残す端末ラベル（機種名/コンピュータ名 + インストール ID 先頭4桁）。
    /// iCloud 同期先で「他端末の進捗表示」と「この端末の実処理」を切り分けるための表示用。
    /// ID の断片を添えるのは、同機種が複数台（iPhone 2台等）でも区別できるようにするため。
    /// - Note: UIDevice.current が MainActor 隔離のため @MainActor（利用側はログ記録＝MainActor のみ）。
    @MainActor
    static let displayLabel: String = {
        // UIDevice.name は iOS 16+ でユーザー設定名を返さない（"iPhone" 等の総称）ため model で十分。
        "\(UIDevice.current.model) \(String(current.prefix(4)))"
    }()
}
