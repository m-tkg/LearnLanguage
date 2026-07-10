import Foundation
import Security

/// Keychain に文字列（API キー等の秘密情報）を保存/取得する薄いラッパ。
/// 項目は同期可能（`kSecAttrSynchronizable`）として保存し、ユーザーが iCloud キーチェーンを
/// 有効にしていれば端末間で自動的に同期される（無効なら従来どおり端末ローカル）。
/// 読み取りは `kSecAttrSynchronizableAny` で、同期化以前に保存された旧項目も引き続き見つかる。
enum KeychainStore {
    private static let service = "com.mtkg.LearnLanguage"

    /// Gemini API キーの Keychain アカウント名。
    static let geminiAPIKeyAccount = "geminiAPIKey"
    /// Pollinations API キー（任意, Seed tier でレート緩和）の Keychain アカウント名。
    static let pollinationsAPIKeyAccount = "pollinationsAPIKey"
    /// Cloudflare Workers AI の Account ID の Keychain アカウント名。
    static let cloudflareAccountIDAccount = "cloudflareAccountID"
    /// Cloudflare Workers AI の API トークンの Keychain アカウント名。
    static let cloudflareAPITokenAccount = "cloudflareAPIToken"

    /// 値を保存する。nil/空文字なら削除。
    static func set(_ value: String?, account: String) {
        // 旧（非同期）・新（同期）どちらの既存項目も消してから入れ直す。
        let delete: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(delete as CFDictionary)

        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            // iCloud キーチェーンでの端末間同期を許可する。
            kSecAttrSynchronizable as String: true,
        ]
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
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
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
