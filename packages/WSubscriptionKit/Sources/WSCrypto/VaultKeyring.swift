import Foundation
import CryptoKit

public struct VaultCreation: Sendable {
    public let fileData: Data
    public let masterKey: SecureBytes
    /// 仅在未提供恢复码时生成；调用方必须立刻展示给用户。
    public let recoveryKey: String
}

/// 信封加密的唯一入口：一把主密钥（MK），三条互相独立的解锁路径。
public enum VaultKeyring {
    static let recoveryPrefix = "ws.recovery.v1|"
    static let biometricInfo = "ws.bio.kek.v1"

    // MARK: - 建库

    public static func create(payload: Data,
                              passphrase: String,
                              recoveryKey: String? = nil,
                              biometricPublicKey: Data? = nil,
                              revision: UInt64 = 1,
                              deviceID: UUID,
                              kdf: KDFParameters = .standard) throws -> VaultCreation {
        let masterKey = try SecureBytes.random(count: 32)
        let saltPass = try CryptoRandom.bytes(16)
        let saltRecovery = try CryptoRandom.bytes(16)
        let saltBio = try CryptoRandom.bytes(16)

        let passKEK = try KDF.derive(passphrase: passphrase, salt: saltPass, parameters: kdf)
        let wrapPass = try KeyWrap.wrap(masterKey, using: passKEK)

        let code: String
        if let recoveryKey, let normalized = RecoveryKey.normalize(recoveryKey) {
            code = normalized
        } else {
            code = try RecoveryKey.generate()
        }
        let recoveryKEK = try KDF.derive(passphrase: recoveryPrefix + code, salt: saltRecovery, parameters: kdf)
        let wrapRecovery = try KeyWrap.wrap(masterKey, using: recoveryKEK)

        var wrapBio = Data()
        if let biometricPublicKey {
            wrapBio = try makeBiometricWrap(masterKey: masterKey, publicKeyData: biometricPublicKey, salt: saltBio)
        }

        var header = VaultHeader(
            formatVersion: VaultHeader.currentFormatVersion,
            flags: 0,
            kdf: kdf,
            saltPass: saltPass,
            saltRecovery: saltRecovery,
            saltBio: saltBio,
            wrapPass: wrapPass,
            wrapBio: wrapBio,
            wrapRecovery: wrapRecovery,
            revision: revision,
            writerDeviceID: deviceID,
            payloadNonce: try CryptoRandom.bytes(12),
            headerMAC: Data()
        )
        let fileData = try VaultFileCodec.seal(payload: payload, header: &header, masterKey: masterKey)
        return VaultCreation(fileData: fileData, masterKey: masterKey, recoveryKey: RecoveryKey.format(code))
    }

    // MARK: - 解锁（三条路径都返回同一把 MK）

    public static func masterKey(passphrase: String, fileData: Data) throws -> SecureBytes {
        let header = try VaultFileCodec.header(of: fileData)
        let kek = try KDF.derive(passphrase: passphrase, salt: header.saltPass, parameters: header.kdf)
        return try KeyWrap.unwrap(header.wrapPass, using: kek)
    }

    public static func masterKey(recoveryKey: String, fileData: Data) throws -> SecureBytes {
        guard let normalized = RecoveryKey.normalize(recoveryKey) else {
            throw CryptoError.credentialRejected
        }
        let header = try VaultFileCodec.header(of: fileData)
        guard !header.wrapRecovery.isEmpty else { throw CryptoError.credentialRejected }
        let kek = try KDF.derive(passphrase: recoveryPrefix + normalized,
                                 salt: header.saltRecovery,
                                 parameters: header.kdf)
        return try KeyWrap.unwrap(header.wrapRecovery, using: kek)
    }

    /// sharedSecretProvider 拿到临时公钥后返回 ECDH 共享密钥（由 Secure Enclave 私钥在前台认证后计算）。
    public static func masterKey(fileData: Data,
                                 sharedSecretProvider: (Data) throws -> SecureBytes) throws -> SecureBytes {
        let header = try VaultFileCodec.header(of: fileData)
        guard header.hasBiometric, header.wrapBio.count == 125 else {
            throw CryptoError.biometryUnavailable
        }
        let ephemeral = header.wrapBio.prefix(65)
        let sealed = header.wrapBio.suffix(from: header.wrapBio.startIndex + 65)
        let shared = try sharedSecretProvider(Data(ephemeral))
        let kek = KDF.hkdf(inputKey: shared, salt: header.saltBio, info: biometricInfo)
        return try KeyWrap.unwrap(Data(sealed), using: kek)
    }

    public static func open(fileData: Data, masterKey: SecureBytes) throws -> Data {
        try VaultFileCodec.open(fileData: fileData, masterKey: masterKey)
    }

    // MARK: - 落盘（只换 nonce 与 revision，不重算 KDF）

    public static func reseal(payload: Data,
                              basedOn fileData: Data,
                              masterKey: SecureBytes,
                              revision: UInt64,
                              deviceID: UUID) throws -> Data {
        var header = try VaultFileCodec.header(of: fileData)
        header.revision = revision
        header.writerDeviceID = deviceID
        header.payloadNonce = try CryptoRandom.bytes(12)
        header.headerMAC = Data()
        return try VaultFileCodec.seal(payload: payload, header: &header, masterKey: masterKey)
    }

    // MARK: - 密钥轮换（都只重包裹 MK，不重新加密负载）

    public static func changePassphrase(fileData: Data,
                                        masterKey: SecureBytes,
                                        newPassphrase: String,
                                        revision: UInt64,
                                        deviceID: UUID,
                                        kdf: KDFParameters = .standard) throws -> Data {
        let payload = try open(fileData: fileData, masterKey: masterKey)
        var header = try VaultFileCodec.header(of: fileData)
        header.saltPass = try CryptoRandom.bytes(16)
        header.kdf = kdf
        let kek = try KDF.derive(passphrase: newPassphrase, salt: header.saltPass, parameters: kdf)
        header.wrapPass = try KeyWrap.wrap(masterKey, using: kek)
        header.revision = revision
        header.writerDeviceID = deviceID
        header.payloadNonce = try CryptoRandom.bytes(12)
        return try VaultFileCodec.seal(payload: payload, header: &header, masterKey: masterKey)
    }

    public static func attachBiometric(fileData: Data,
                                       masterKey: SecureBytes,
                                       biometricPublicKey: Data,
                                       revision: UInt64,
                                       deviceID: UUID) throws -> Data {
        let payload = try open(fileData: fileData, masterKey: masterKey)
        var header = try VaultFileCodec.header(of: fileData)
        header.saltBio = try CryptoRandom.bytes(16)
        header.wrapBio = try makeBiometricWrap(masterKey: masterKey,
                                               publicKeyData: biometricPublicKey,
                                               salt: header.saltBio)
        header.revision = revision
        header.writerDeviceID = deviceID
        header.payloadNonce = try CryptoRandom.bytes(12)
        return try VaultFileCodec.seal(payload: payload, header: &header, masterKey: masterKey)
    }

    public static func detachBiometric(fileData: Data,
                                       masterKey: SecureBytes,
                                       revision: UInt64,
                                       deviceID: UUID) throws -> Data {
        let payload = try open(fileData: fileData, masterKey: masterKey)
        var header = try VaultFileCodec.header(of: fileData)
        header.wrapBio = Data()
        header.revision = revision
        header.writerDeviceID = deviceID
        header.payloadNonce = try CryptoRandom.bytes(12)
        return try VaultFileCodec.seal(payload: payload, header: &header, masterKey: masterKey)
    }

    public static func rotateRecoveryKey(fileData: Data,
                                         masterKey: SecureBytes,
                                         newRecoveryKey: String?,
                                         revision: UInt64,
                                         deviceID: UUID,
                                         kdf: KDFParameters = .standard) throws -> (code: String, fileData: Data) {
        let payload = try open(fileData: fileData, masterKey: masterKey)
        var header = try VaultFileCodec.header(of: fileData)
        let code: String
        if let newRecoveryKey, let normalized = RecoveryKey.normalize(newRecoveryKey) {
            code = normalized
        } else {
            code = try RecoveryKey.generate()
        }
        header.saltRecovery = try CryptoRandom.bytes(16)
        let kek = try KDF.derive(passphrase: recoveryPrefix + code, salt: header.saltRecovery, parameters: kdf)
        header.wrapRecovery = try KeyWrap.wrap(masterKey, using: kek)
        header.revision = revision
        header.writerDeviceID = deviceID
        header.payloadNonce = try CryptoRandom.bytes(12)
        let data = try VaultFileCodec.seal(payload: payload, header: &header, masterKey: masterKey)
        return (RecoveryKey.format(code), data)
    }

    // MARK: - 内部

    /// Security 框架导出 65 字节（0x04 || x || y），CryptoKit 用 64 字节。
    /// 文件里统一存 65 字节，方便直接交给 SecKeyCreateWithData。
    static func x963(_ raw: Data) -> Data {
        raw.count == 64 ? Data([0x04]) + raw : raw
    }

    static func compact(_ x963: Data) -> Data {
        x963.count == 65 && x963.first == 0x04 ? Data(x963.dropFirst()) : x963
    }

    static func makeBiometricWrap(masterKey: SecureBytes, publicKeyData: Data, salt: Data) throws -> Data {
        let peer = try P256.KeyAgreement.PublicKey(rawRepresentation: compact(publicKeyData))
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: peer)
        let sharedBytes = shared.withUnsafeBytes { SecureBytes($0) }
        let kek = KDF.hkdf(inputKey: sharedBytes, salt: salt, info: biometricInfo)
        let wrapped = try KeyWrap.wrap(masterKey, using: kek)
        var output = x963(ephemeral.publicKey.rawRepresentation)
        output.append(wrapped)
        return output
    }
}
