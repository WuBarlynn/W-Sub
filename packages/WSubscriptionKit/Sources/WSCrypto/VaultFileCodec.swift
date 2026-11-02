import Foundation
import CryptoKit

/// 文件头：明文但被认证。解密所需的公开参数（KDF、salt、包裹段、nonce）必须明文，
/// 但任何字段被改动都会导致 HeaderMAC 或 AEAD 校验失败。
public struct VaultHeader: Sendable, Equatable {
    public static let magic: [UInt8] = [0x57, 0x53, 0x56, 0x4C] // "WSVL"
    public static let currentFormatVersion: UInt16 = 1
    public static let flagBiometric: UInt16 = 1 << 0
    public static let flagRecovery: UInt16 = 1 << 1

    public var formatVersion: UInt16
    public var flags: UInt16
    public var kdf: KDFParameters
    public var saltPass: Data      // 16，仅用于口令派生
    public var saltRecovery: Data  // 16，仅用于恢复码派生（与口令解耦，改密码不会废掉恢复码）
    public var saltBio: Data       // 16，用于生物识别 KEK 派生
    public var wrapPass: Data      // 60 (nonce12 + ct32 + tag16)
    public var wrapBio: Data       // 125 或空
    public var wrapRecovery: Data  // 60 或空
    public var revision: UInt64
    public var writerDeviceID: UUID
    public var payloadNonce: Data  // 12
    public var headerMAC: Data     // 32

    public var hasBiometric: Bool { flags & VaultHeader.flagBiometric != 0 }
    public var hasRecovery: Bool { flags & VaultHeader.flagRecovery != 0 }

    /// 被 MAC 覆盖的字节（不含 headerMAC 本身），同时作为负载解密的 AAD。
    public func macInput() -> Data {
        var writer = ByteWriter()
        writer.appendBytes(VaultHeader.magic)
        writer.appendUInt16(formatVersion)
        writer.appendUInt16(flags)
        writer.appendUInt8(kdf.id)
        writer.appendUInt32(kdf.iterations)
        writer.appendData(saltPass)
        writer.appendData(saltRecovery)
        writer.appendData(saltBio)
        writer.appendLengthPrefixed(wrapPass)
        writer.appendLengthPrefixed(wrapBio)
        writer.appendLengthPrefixed(wrapRecovery)
        writer.appendUInt64(revision)
        writer.appendData(VaultHeader.uuidBytes(writerDeviceID))
        writer.appendData(payloadNonce)
        return writer.data
    }

    public func encoded() -> Data {
        var data = macInput()
        data.append(headerMAC)
        return data
    }

    public var encodedSize: Int { macInput().count + 32 }

    static func uuidBytes(_ uuid: UUID) -> Data {
        withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }

    static func uuid(from data: Data) -> UUID? {
        guard data.count == 16 else { return nil }
        let bytes = [UInt8](data)
        let tuple: uuid_t = (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                             bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
        return UUID(uuid: tuple)
    }
}

public enum VaultFileCodec {
    /// 组装并加密：header.payloadNonce 必须先设好，因为 nonce 参与 AAD。
    public static func seal(payload: Data,
                            header: inout VaultHeader,
                            masterKey: SecureBytes) throws -> Data {
        header.formatVersion = VaultHeader.currentFormatVersion
        header.flags = 0
        if !header.wrapBio.isEmpty { header.flags |= VaultHeader.flagBiometric }
        if !header.wrapRecovery.isEmpty { header.flags |= VaultHeader.flagRecovery }

        let payloadKey = KDF.hkdf(inputKey: masterKey, salt: Data(), info: "ws.payload.v1")
        let aad = header.macInput()
        let nonce = try AES.GCM.Nonce(data: header.payloadNonce)
        let box = try AES.GCM.seal(payload, using: payloadKey.symmetricKey, nonce: nonce, authenticating: aad)

        let macKey = KDF.hkdf(inputKey: masterKey, salt: Data(), info: "ws.header.mac.v1")
        let mac = HMAC<SHA256>.authenticationCode(for: aad, using: macKey.symmetricKey)
        header.headerMAC = Data(mac)

        var output = header.encoded()
        output.append(box.ciphertext)
        output.append(box.tag)
        return output
    }

    public static func parse(_ data: Data) throws -> (header: VaultHeader, body: Data) {
        var reader = ByteReader(data)
        guard try reader.readBytes(4) == Data(VaultHeader.magic) else { throw CryptoError.badMagic }
        let version = try reader.readUInt16()
        guard version <= VaultHeader.currentFormatVersion else {
            throw CryptoError.unsupportedVersion(version)
        }
        let flags = try reader.readUInt16()
        let kdfID = try reader.readUInt8()
        let iterations = try reader.readUInt32()
        let saltPass = try reader.readData(16)
        let saltRecovery = try reader.readData(16)
        let saltBio = try reader.readData(16)
        let wrapPass = try reader.readLengthPrefixed(max: 4_096)
        let wrapBio = try reader.readLengthPrefixed(max: 4_096)
        let wrapRecovery = try reader.readLengthPrefixed(max: 4_096)
        let revision = try reader.readUInt64()
        let uuidData = try reader.readData(16)
        guard let deviceID = VaultHeader.uuid(from: uuidData) else { throw CryptoError.malformedHeader }
        let nonce = try reader.readData(12)
        let mac = try reader.readData(32)

        guard wrapPass.count == 60, nonce.count == 12 else { throw CryptoError.malformedHeader }

        let header = VaultHeader(
            formatVersion: version,
            flags: flags,
            kdf: KDFParameters(id: kdfID, iterations: iterations),
            saltPass: saltPass,
            saltRecovery: saltRecovery,
            saltBio: saltBio,
            wrapPass: wrapPass,
            wrapBio: wrapBio,
            wrapRecovery: wrapRecovery,
            revision: revision,
            writerDeviceID: deviceID,
            payloadNonce: nonce,
            headerMAC: mac
        )
        let body = data.subdata(in: reader.offset..<data.count)
        guard body.count > 16 else { throw CryptoError.malformedHeader }
        return (header, body)
    }

    /// 校验头部 MAC 并解密负载。
    public static func open(fileData: Data, masterKey: SecureBytes) throws -> Data {
        let (header, body) = try parse(fileData)

        let macKey = KDF.hkdf(inputKey: masterKey, salt: Data(), info: "ws.header.mac.v1")
        let expected = HMAC<SHA256>.authenticationCode(for: header.macInput(), using: macKey.symmetricKey)
        guard constantTimeEquals(header.headerMAC, Data(expected)) else {
            throw CryptoError.integrityFailure
        }

        let payloadKey = KDF.hkdf(inputKey: masterKey, salt: Data(), info: "ws.payload.v1")
        let ciphertext = body.prefix(body.count - 16)
        let tag = body.suffix(16)
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: header.payloadNonce),
                                            ciphertext: Data(ciphertext),
                                            tag: Data(tag))
            return try AES.GCM.open(box, using: payloadKey.symmetricKey, authenticating: header.macInput())
        } catch {
            throw CryptoError.integrityFailure
        }
    }

    public static func header(of fileData: Data) throws -> VaultHeader {
        try parse(fileData).header
    }
}

// MARK: - 主密钥包裹

public enum KeyWrap {
    public static func wrap(_ key: SecureBytes, using kek: SecureBytes) throws -> Data {
        let box = try AES.GCM.seal(Data(key.bytes), using: kek.symmetricKey)
        guard let combined = box.combined, combined.count == 60 else { throw CryptoError.malformedHeader }
        return combined
    }

    public static func unwrap(_ data: Data, using kek: SecureBytes) throws -> SecureBytes {
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            let plaintext = try AES.GCM.open(box, using: kek.symmetricKey)
            return SecureBytes(plaintext)
        } catch {
            throw CryptoError.credentialRejected
        }
    }
}

// MARK: - 二进制读写

struct ByteWriter {
    var data = Data()
    mutating func appendUInt8(_ value: UInt8) { data.append(value) }
    mutating func appendUInt16(_ value: UInt16) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
    mutating func appendUInt32(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            data.append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }
    mutating func appendUInt64(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }
    mutating func appendData(_ value: Data) { data.append(value) }
    mutating func appendBytes(_ value: [UInt8]) { data.append(contentsOf: value) }
    mutating func appendLengthPrefixed(_ value: Data) {
        appendUInt16(UInt16(clamping: value.count))
        appendData(value)
    }
}

struct ByteReader {
    private let data: Data
    private(set) var offset: Int = 0

    init(_ data: Data) { self.data = data }

    var isAtEnd: Bool { offset >= data.count }

    mutating func readBytes(_ count: Int) throws -> Data {
        guard offset + count <= data.count else { throw CryptoError.malformedHeader }
        let slice = data.subdata(in: offset..<(offset + count))
        offset += count
        return slice
    }

    mutating func readData(_ count: Int) throws -> Data { try readBytes(count) }

    mutating func readUInt8() throws -> UInt8 {
        let bytes = try readBytes(1)
        return bytes[bytes.startIndex]
    }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = [UInt8](try readBytes(2))
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = [UInt8](try readBytes(4))
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    mutating func readUInt64() throws -> UInt64 {
        let bytes = [UInt8](try readBytes(8))
        var value: UInt64 = 0
        for byte in bytes { value = (value << 8) | UInt64(byte) }
        return value
    }

    mutating func readLengthPrefixed(max: Int) throws -> Data {
        let length = Int(try readUInt16())
        guard length <= max else { throw CryptoError.malformedHeader }
        return try readBytes(length)
    }
}
