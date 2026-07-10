import XCTest
@testable import LearnLanguage

/// 設定の iCloud 同期（UserDefaults ⇄ iCloud KVS のミラーリング）のテスト。
/// 実際のストアの代わりに辞書ベースのフェイクを使い、同期の向き・衝突時の優先・ループ防止を固定する。
@MainActor
final class SettingsCloudSyncTests: XCTestCase {

    /// 辞書ベースのフェイクストア。書き込み回数も記録する（無限ループ検出用）。
    final class FakeStore: SettingsKeyValueStore, @unchecked Sendable {
        private(set) var storage: [String: Any]
        private(set) var writeCount = 0
        init(_ storage: [String: Any] = [:]) { self.storage = storage }
        func settingsValue(forKey key: String) -> Any? { storage[key] }
        func setSettingsValue(_ value: Any?, forKey key: String) {
            writeCount += 1
            storage[key] = value
        }
    }

    private let keys = ["nativeLanguageCode", "speechRate"]

    func testPullAppliesCloudValuesToLocal() {
        let cloud = FakeStore(["nativeLanguageCode": "en", "speechRate": 0.7])
        let local = FakeStore(["nativeLanguageCode": "ja"])
        let sync = SettingsCloudSync(local: local, cloud: cloud, keys: keys)

        sync.pullFromCloud()

        XCTAssertEqual(local.storage["nativeLanguageCode"] as? String, "en", "衝突時はクラウド優先")
        XCTAssertEqual(local.storage["speechRate"] as? Double, 0.7, "クラウドにだけある値も取り込む")
    }

    func testPullSkipsEqualValues() {
        let cloud = FakeStore(["nativeLanguageCode": "ja"])
        let local = FakeStore(["nativeLanguageCode": "ja"])
        let sync = SettingsCloudSync(local: local, cloud: cloud, keys: keys)

        sync.pullFromCloud()

        XCTAssertEqual(local.writeCount, 0, "同じ値は書き込まない（変更通知ループを起こさない）")
    }

    func testPushUploadsLocalValuesToCloud() {
        let cloud = FakeStore()
        let local = FakeStore(["nativeLanguageCode": "ja", "speechRate": 0.5])
        let sync = SettingsCloudSync(local: local, cloud: cloud, keys: keys)

        sync.pushToCloud()

        XCTAssertEqual(cloud.storage["nativeLanguageCode"] as? String, "ja")
        XCTAssertEqual(cloud.storage["speechRate"] as? Double, 0.5)
    }

    func testPushSkipsEqualValues() {
        let cloud = FakeStore(["speechRate": 0.5])
        let local = FakeStore(["speechRate": 0.5])
        let sync = SettingsCloudSync(local: local, cloud: cloud, keys: keys)

        sync.pushToCloud()

        XCTAssertEqual(cloud.writeCount, 0, "同じ値は書き込まない")
    }

    func testPushDoesNotUploadKeysOutsideSyncList() {
        let cloud = FakeStore()
        let local = FakeStore(["secretLocalOnly": "x", "nativeLanguageCode": "ja"])
        let sync = SettingsCloudSync(local: local, cloud: cloud, keys: keys)

        sync.pushToCloud()

        XCTAssertNil(cloud.storage["secretLocalOnly"], "同期対象キー以外はクラウドに送らない")
    }

    func testPullThenPushConverges() {
        // 初回起動フロー: pull（クラウド優先で取り込み）→ push（ローカルにしか無い値を上げる）で両者が揃う。
        let cloud = FakeStore(["nativeLanguageCode": "en"])
        let local = FakeStore(["speechRate": 0.3])
        let sync = SettingsCloudSync(local: local, cloud: cloud, keys: keys)

        sync.pullFromCloud()
        sync.pushToCloud()

        XCTAssertEqual(local.storage["nativeLanguageCode"] as? String, "en")
        XCTAssertEqual(cloud.storage["speechRate"] as? Double, 0.3)
    }
}
