import Foundation
import Security

/// Minimal Keychain wrapper.
public enum Keychain {
    /// SMB credentials for the NAS remount, stored as "user\npassword".
    public static let nasCredentialsService = "offload-nas-smb"
    /// Anthropic API key for AI photo analysis in API mode (CLI mode needs none).
    public static let aiAPIKeyService = "offload-anthropic-api-key"

    public static func set(_ value: String, service: String, account: String = "default") {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // ThisDeviceOnly: these NAS credentials never leave this Mac (no iCloud
        // Keychain sync, not included in encrypted backups restored to another device).
        let accessible = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = accessible
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public static func get(service: String, account: String = "default") -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(service: String, account: String = "default") {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
