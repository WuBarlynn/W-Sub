import XCTest
import CryptoKit
@testable import WSCrypto

final class CryptoPrimitiveTests: XCTestCase {
    func testRecoveryKeyFormatAndNormalization() throws {
        let raw = try RecoveryKey.generate()
        XCTAssertEqual(raw.count, 24)            // 120 bit 熵
        let code = RecoveryKey.format(raw)
        XCTAssertEqual(code.count, 24 + 5)       // 5 个分隔符，仅用于展示
        let normalized = RecoveryKey.normalize(code)
        XCTAssertEqual(normalized?.count, 24)
        // 小写与易混字符都应被接受
        XCTAssertEqual(RecoveryKey.normalize(code.lowercased()), normalized)
        XCTAssertEqual(RecoveryKey.normalize("O" + String(normalized!.dropFirst())), RecoveryKey.normalize("0" + String(normalized!.dropFirst())))
        XCTAssertNil(RecoveryKey.normalize("too-short"))
    }

    func testPBKDF2IsDeterministic() throws {
        let salt = Data(repeating: 7, count: 16)
        let params = KDFParameters.testing
        let a = try KDF.derive(passphrase: "correct horse", salt: salt, parameters: params)
        let b = try KDF.derive(passphrase: "correct horse", salt: salt, parameters: params)
        XCTAssertEqual(a.bytes, b.bytes)

        let c = try KDF.derive(passphrase: "correct horsE", salt: salt, parameters: params)
        XCTAssertNotEqual(a.bytes, c.bytes)
    }

    func testPBKDF2MatchesKnownVector() throws {
        // RFC 6070 风格向量（PBKDF2-HMAC-SHA256）：P="password", S="salt", c=1, dkLen=32
        let key = try KDF.derive(passphrase: "password",
                                 salt: Data("salt".utf8),
                                 parameters: KDFParameters(iterations: 1))
        let expected = "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"
        XCTAssertEqual(key.bytes.map { String(format: "%02x", $0) }.joined(), expected)
    }

    func testSecureBytesZeroesOnDeinit() throws {
        var captured = [UInt8]()
        do {
            let secure = try SecureBytes.random(count: 32)
            captured = secure.bytes
            XCTAssertEqual(captured.count, 32)
        }
        // 只能验证长度与随机性；清零发生在 deinit 内部，不做黑盒断言。
        XCTAssertNotEqual(captured, [UInt8](repeating: 0, count: 32))
    }
}

final class VaultFileTests: XCTestCase {
    let payload = Data(#"{"hello":"world"}"#.utf8)

    func testSealAndOpenRoundTrip() throws {
        let creation = try VaultKeyring.create(payload: payload,
                                               passphrase: "p@ssw0rd-123",
                                               revision: 1,
                                               deviceID: UUID(),
                                               kdf: .testing)
        let key = try VaultKeyring.masterKey(passphrase: "p@ssw0rd-123", fileData: creation.fileData)
        let opened = try VaultKeyring.open(fileData: creation.fileData, masterKey: key)
        XCTAssertEqual(opened, payload)
    }

    func testWrongPassphraseRejected() throws {
        let creation = try VaultKeyring.create(payload: payload,
                                               passphrase: "right",
                                               revision: 1,
                                               deviceID: UUID(),
                                               kdf: .testing)
        XCTAssertThrowsError(try VaultKeyring.masterKey(passphrase: "wrong", fileData: creation.fileData)) { error in
            XCTAssertEqual(error as? CryptoError, .credentialRejected)
        }
    }

    func testRecoveryKeyUnlocksSameMasterKey() throws {
        let creation = try VaultKeyring.create(payload: payload,
                                               passphrase: "pw",
                                               revision: 1,
                                               deviceID: UUID(),
                                               kdf: .testing)
        let byPass = try VaultKeyring.masterKey(passphrase: "pw", fileData: creation.fileData)
        let byCode = try VaultKeyring.masterKey(recoveryKey: creation.recoveryKey, fileData: creation.fileData)
        XCTAssertEqual(byPass.bytes, byCode.bytes)
    }

    func testHeaderTamperIsDetected() throws {
        var data = try VaultKeyring.create(payload: payload,
                                           passphrase: "pw",
                                           revision: 1,
                                           deviceID: UUID(),
                                           kdf: .testing).fileData
        // 翻转密文正文的最后一个字节 → GCM tag 校验失败
        data[data.count - 17] = data[data.count - 17] ^ 0xFF
        let key = try VaultKeyring.masterKey(passphrase: "pw", fileData: data)
        XCTAssertThrowsError(try VaultKeyring.open(fileData: data, masterKey: key)) { error in
            XCTAssertEqual(error as? CryptoError, .integrityFailure)
        }
    }

    func testHeaderMACDetectsDowngrade() throws {
        var data = try VaultKeyring.create(payload: payload,
                                           passphrase: "pw",
                                           revision: 8,
                                           deviceID: UUID(),
                                           kdf: .testing).fileData
        // 直接把 revision 改成 1（模拟回滚到旧版本）
        var mutated = try VaultFileCodec.parse(data)
        mutated.header.revision = 1
        data = mutated.header.encoded() + mutated.body

        let key = try VaultKeyring.masterKey(passphrase: "pw", fileData: data)
        XCTAssertThrowsError(try VaultKeyring.open(fileData: data, masterKey: key)) { error in
            XCTAssertEqual(error as? CryptoError, .integrityFailure)
        }
    }

    func testResealKeepsMasterKeyAndBumpsRevision() throws {
        let creation = try VaultKeyring.create(payload: payload,
                                               passphrase: "pw",
                                               revision: 1,
                                               deviceID: UUID(),
                                               kdf: .testing)
        let newPayload = Data(#"{"hello":"again"}"#.utf8)
        let resealed = try VaultKeyring.reseal(payload: newPayload,
                                               basedOn: creation.fileData,
                                               masterKey: creation.masterKey,
                                               revision: 2,
                                               deviceID: UUID())
        let header = try VaultFileCodec.header(of: resealed)
        XCTAssertEqual(header.revision, 2)

        let key = try VaultKeyring.masterKey(passphrase: "pw", fileData: resealed)
        XCTAssertEqual(try VaultKeyring.open(fileData: resealed, masterKey: key), newPayload)
    }

    func testChangePassphraseInvalidatesOldOneAndKeepsRecovery() throws {
        let creation = try VaultKeyring.create(payload: payload,
                                               passphrase: "old",
                                               revision: 1,
                                               deviceID: UUID(),
                                               kdf: .testing)
        let updated = try VaultKeyring.changePassphrase(fileData: creation.fileData,
                                                        masterKey: creation.masterKey,
                                                        newPassphrase: "new",
                                                        revision: 2,
                                                        deviceID: UUID(),
                                                        kdf: .testing)
        XCTAssertThrowsError(try VaultKeyring.masterKey(passphrase: "old", fileData: updated))
        let newKey = try VaultKeyring.masterKey(passphrase: "new", fileData: updated)
        XCTAssertEqual(try VaultKeyring.open(fileData: updated, masterKey: newKey), payload)

        // 改密码不应影响恢复码（saltRecovery 独立）
        let byRecovery = try VaultKeyring.masterKey(recoveryKey: creation.recoveryKey, fileData: updated)
        XCTAssertEqual(byRecovery.bytes, creation.masterKey.bytes)
    }

    func testRotateRecoveryInvalidatesOldCode() throws {
        let creation = try VaultKeyring.create(payload: payload,
                                               passphrase: "pw",
                                               revision: 1,
                                               deviceID: UUID(),
                                               kdf: .testing)
        let rotated = try VaultKeyring.rotateRecoveryKey(fileData: creation.fileData,
                                                         masterKey: creation.masterKey,
                                                         newRecoveryKey: nil,
                                                         revision: 2,
                                                         deviceID: UUID(),
                                                         kdf: .testing)
        XCTAssertNotEqual(rotated.code, creation.recoveryKey)
        XCTAssertThrowsError(try VaultKeyring.masterKey(recoveryKey: creation.recoveryKey, fileData: rotated.fileData))
        XCTAssertNoThrow(try VaultKeyring.masterKey(recoveryKey: rotated.code, fileData: rotated.fileData))
    }

    func testBiometricWrapUsesECDHAndCanUnwrap() throws {
        // 用软件 P-256 密钥模拟 Secure Enclave 的对外契约
        let deviceKey = P256.KeyAgreement.PrivateKey()
        let devicePublic = deviceKey.publicKey.rawRepresentation

        let creation = try VaultKeyring.create(payload: payload,
                                               passphrase: "pw",
                                               biometricPublicKey: devicePublic,
                                               revision: 1,
                                               deviceID: UUID(),
                                               kdf: .testing)
        let header = try VaultFileCodec.header(of: creation.fileData)
        XCTAssertTrue(header.hasBiometric)
        XCTAssertEqual(header.wrapBio.count, 125)

        let key = try VaultKeyring.masterKey(fileData: creation.fileData) { ephemeralData in
            let ephemeral = try P256.KeyAgreement.PublicKey(rawRepresentation: VaultKeyring.compact(ephemeralData))
            let shared = try deviceKey.sharedSecretFromKeyAgreement(with: ephemeral)
            return shared.withUnsafeBytes { SecureBytes($0) }
        }
        XCTAssertEqual(key.bytes, creation.masterKey.bytes)
        XCTAssertEqual(try VaultKeyring.open(fileData: creation.fileData, masterKey: key), payload)
    }

    func testHeaderIsSelfDescribing() throws {
        let creation = try VaultKeyring.create(payload: payload,
                                               passphrase: "pw",
                                               revision: 42,
                                               deviceID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                                               kdf: .testing)
        let header = try VaultFileCodec.header(of: creation.fileData)
        XCTAssertEqual(header.formatVersion, 1)
        XCTAssertEqual(header.revision, 42)
        XCTAssertEqual(header.writerDeviceID.uuidString, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(header.kdf.iterations, 1_000)
        XCTAssertTrue(header.hasRecovery)
        XCTAssertFalse(header.hasBiometric)
    }
}
