import Foundation
import Security

/// Keychain に文字列（API キー等の秘密情報）を保存/取得する薄いラッパ。
enum KeychainStore {
    private static let service = "com.mtkg.LearnLanguage"

    /// Gemini API キーの Keychain アカウント名。
    static let geminiAPIKeyAccount = "geminiAPIKey"
    /// Pollinations API キー（任意, Seed tier でレート緩和）の Keychain アカウント名。
    static let pollinationsAPIKeyAccount = "pollinationsAPIKey"

    /// 値を保存する。nil/空文字なら削除。
    static func set(_ value: String?, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)

        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    /// 値を取得する。無ければ nil。
    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// 値が設定されているか。
    static func exists(account: String) -> Bool {
        get(account: account)?.isEmpty == false
    }
}
