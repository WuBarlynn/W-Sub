import Foundation
import Security

/// 主密钥（MK）的钥匙串存取。
///
/// 默认模式下：库文件在磁盘上仍是密文，但 MK 存在钥匙串里，App 启动时直接读取静默解锁，
/// 用户无需输密码或 Face ID。这把「只加密库、不锁 App」和「数据密文落盘」两者兼得。
///
/// 安全性说明：钥匙串受设备保护（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`），
/// 不能随备份迁移到别的设备，卸载 App 后会被清除。对「本地防窥」场景足够；
/// 若需要更强的防护，用户可额外开启密码/生物识别（保留的高级路径）。
public enum MasterKeyStore {
    private static let service = "app.wsubscription.masterkey.v1"
    private static let account = "vault"

    @discardableResult
    public static func save(_ key: SecureBytes) -> OSStatus {
        delete()
        let data = key.bytes
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(data),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            // 无签名构建/缺少 keychain-access-groups 时可能 -34018，退化为可访问性更宽松的重试
            var retry = query
            retry[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            return SecItemAdd(retry as CFDictionary, nil)
        }
        return status
    }

    public static func load() -> SecureBytes? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else {
            return nil
        }
        return SecureBytes(data)
    }

    public static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
