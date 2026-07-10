import XCTest
import Security
@testable import LearnLanguage

/// Keychain の同期属性マイグレーション（旧・端末ローカル項目 → iCloud キーチェーン同期可能項目）のテスト。
/// Simulator の Keychain は実 API で動作する。テスト専用の account 名を使い、後始末で消す。
final class KeychainStoreTests: XCTestCase {
    private let testAccount = "test-migration-account"

    override func tearDown() {
        deleteAll(account: testAccount)
        super.tearDown()
    }

    func testMigrationRewritesLocalOnlyItemAsSynchronizable() {
        // 同期対応前の保存を再現: kSecAttrSynchronizable なしで直接追加。
        addRawLocalItem(value: "legacy-secret", account: testAccount)
        XCTAssertNil(copyValue(account: testAccount, synchronizable: true), "前提: 同期項目はまだ無い")

        KeychainStore.migrateToSynchronizable(accounts: [testAccount])

        XCTAssertEqual(copyValue(account: testAccount, synchronizable: true), "legacy-secret",
                       "旧ローカル項目が同期可能な項目として書き直される")
        XCTAssertEqual(KeychainStore.get(account: testAccount), "legacy-secret", "値は失われない")
    }

    func testMigrationSkipsWhenSynchronizableItemAlreadyExists() {
        // 他端末から同期済みの新しい値がある状況を再現。
        KeychainStore.set("synced-newer-value", account: testAccount)
        // その上で古いローカル項目も共存させる（set は Any で消すため、raw で後から追加）。
        addRawLocalItem(value: "stale-local-value", account: testAccount)

        KeychainStore.migrateToSynchronizable(accounts: [testAccount])

        XCTAssertEqual(copyValue(account: testAccount, synchronizable: true), "synced-newer-value",
                       "同期項目が既にあれば、古いローカル値で上書きしない")
    }

    func testMigrationDoesNothingForMissingAccount() {
        KeychainStore.migrateToSynchronizable(accounts: ["never-saved-account"])
        XCTAssertNil(KeychainStore.get(account: "never-saved-account"))
    }

    // MARK: - set の更新セマンティクス（削除→追加の「消失ウィンドウ」が無いこと）

    func testSetTwiceUpdatesValueInPlace() {
        KeychainStore.set("first", account: testAccount)
        KeychainStore.set("second", account: testAccount)
        XCTAssertEqual(KeychainStore.get(account: testAccount), "second")
        XCTAssertEqual(copyValue(account: testAccount, synchronizable: true), "second",
                       "2回目の保存も同期可能な項目として更新される")
    }

    func testSetOverLegacyLocalItemLeavesOnlySynchronizable() {
        // 旧形式（ローカル）の項目が残っている状態で保存し直す。
        addRawLocalItem(value: "legacy", account: testAccount)

        KeychainStore.set("new-value", account: testAccount)

        XCTAssertEqual(copyValue(account: testAccount, synchronizable: true), "new-value")
        XCTAssertNil(copyValue(account: testAccount, synchronizable: false),
                     "旧ローカル項目は掃除され、二重存在しない")
        XCTAssertEqual(KeychainStore.get(account: testAccount), "new-value")
    }

    func testSetEmptyDeletesBothVariants() {
        addRawLocalItem(value: "legacy", account: testAccount)
        KeychainStore.set("value", account: testAccount)

        KeychainStore.set("", account: testAccount)

        XCTAssertNil(KeychainStore.get(account: testAccount))
        XCTAssertNil(copyValue(account: testAccount, synchronizable: true))
        XCTAssertNil(copyValue(account: testAccount, synchronizable: false))
    }

    // MARK: - Keychain 直接操作ヘルパ

    private var service: String { "com.mtkg.LearnLanguage" }

    /// 同期属性なし（旧形式）の項目を直接追加する。
    private func addRawLocalItem(value: String, account: String) {
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(add as CFDictionary, nil)
    }

    private func copyValue(account: String, synchronizable: Bool) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: synchronizable,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteAll(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
