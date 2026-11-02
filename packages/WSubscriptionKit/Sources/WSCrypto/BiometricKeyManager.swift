import Foundation
import CryptoKit
import LocalAuthentication
import Security

/// 生物识别密钥：优先放进 Secure Enclave（私钥不可导出），模拟器/无 SE 设备退回
/// 「Keychain 中的软件 P-256 私钥」。两条路径的对外格式完全一致（X9.63 公钥 + ECDH），
/// 因此文件格式与解锁流程不需要分叉。
public struct BiometricKeyManager: Sendable {
    public let applicationTag: String

    public init(applicationTag: String = "app.wsubscription.biolock.v1") {
        self.applicationTag = applicationTag
    }

    private var tagData: Data { Data(applicationTag.utf8) }

    // MARK: - 能力检测

    public enum BiometryKind: String, Sendable {
        case faceID, touchID, opticID, none

        public var displayName: String {
            switch self {
            case .faceID: return "Face ID"
            case .touchID: return "Touch ID"
            case .opticID: return "Optic ID"
            case .none: return "生物识别"
            }
        }
    }

    public func biometryKind() -> BiometryKind {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return .none
        }
    }

    public var supportsSecureEnclave: Bool {
        SecureEnclave.isAvailable
    }

    // MARK: - 生命周期

    public func deleteKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tagData,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 创建（或重建）密钥，返回 X9.63 未压缩公钥（65 字节）。
    /// 创建过程本身不需要用户认证 —— 只有「使用」私钥时才弹窗。
    @discardableResult
    public func createKey(requireBiometry: Bool = true) throws -> Data {
        deleteKey()

        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            requireBiometry ? [.privateKeyUsage, .biometryCurrentSet] : [.privateKeyUsage, .userPresence],
            &error
        ) else {
            throw CryptoError.keychainFailure(errSecParam)
        }

        var privateAttrs: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: tagData,
            kSecAttrAccessControl as String: access
        ]

        var attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: privateAttrs
        ]

        if SecureEnclave.isAvailable {
            attrs[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        } else {
            privateAttrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
            attrs[kSecPrivateKeyAttrs as String] = privateAttrs
        }

        guard let privateKey = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
            let status = Int32((error?.takeRetainedValue()).map { CFErrorGetCode($0) } ?? Int(errSecInternalError))
            // 设备未设锁屏密码、或未录入生物特征时回退到「用户在场」策略
            if requireBiometry {
                return try createKey(requireBiometry: false)
            }
            throw CryptoError.keychainFailure(status)
        }

        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let external = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw CryptoError.keychainFailure(errSecInternalError)
        }
        return external
    }

    public func existingPublicKey() -> Data? {
        guard let privateKey = copyPrivateKey(context: nil) else { return nil }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { return nil }
        var error: Unmanaged<CFError>?
        return SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
    }

    public func hasKey() -> Bool {
        existingPublicKey() != nil
    }

    // MARK: - ECDH

    /// 用受生物特征保护的私钥与临时公钥做 ECDH。此时系统会弹出 Face ID / Touch ID。
    public func sharedSecret(ephemeralPublicKey: Data,
                             prompt: String = "解锁你的订阅保险箱",
                             context: LAContext? = nil) throws -> SecureBytes {
        guard let privateKey = copyPrivateKey(context: context, prompt: prompt) else {
            throw CryptoError.biometryUnavailable
        }

        var error: Unmanaged<CFError>?
        let peerAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 256
        ]
        guard let peer = SecKeyCreateWithData(ephemeralPublicKey as CFData, peerAttrs as CFDictionary, &error) else {
            throw CryptoError.malformedHeader
        }

        let params: [String: Any] = [SecKeyKeyExchangeParameter.requestedSize.rawValue as String: 32]
        guard let result = SecKeyCopyKeyExchangeResult(privateKey,
                                                      .ecdhKeyExchangeStandard,
                                                      peer,
                                                      params as CFDictionary,
                                                      &error) as Data? else {
            throw CryptoError.biometryUnavailable
        }

        // P-256 的共享密钥是 32 字节 x 坐标；保险起见对异常长度做归一化。
        let normalized = result.count > 32 ? result.suffix(32) : result
        return SecureBytes(normalized)
    }

    private func copyPrivateKey(context: LAContext?, prompt: String? = nil) -> SecKey? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tagData,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true
        ]
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }
        if let prompt {
            query[kSecUseOperationPrompt as String] = prompt
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let item else { return nil }
        // 只有 SecKey 才能强转成功
        return (item as! SecKey)
    }
}
