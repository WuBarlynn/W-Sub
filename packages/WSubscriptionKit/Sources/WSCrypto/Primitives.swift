import Foundation
import CryptoKit
import Security
#if canImport(Darwin)
import Darwin
#endif

public enum CryptoError: Error, LocalizedError, Sendable, Equatable {
    case randomFailed
    case badMagic
    case unsupportedVersion(UInt16)
    case unsupportedKDF(UInt8)
    case malformedHeader
    case integrityFailure
    case credentialRejected
    case biometryUnavailable
    case keychainFailure(Int32)

    public var errorDescription: String? {
        switch self {
        case .randomFailed: return "安全随机数生成失败"
        case .badMagic: return "不是有效的保险箱文件"
        case .unsupportedVersion(let v): return "文件格式版本 \(v) 不受支持"
        case .unsupportedKDF(let id): return "未知的密钥派生算法（\(id)）"
        case .malformedHeader: return "文件头损坏"
        case .integrityFailure: return "完整性校验失败，文件可能被篡改或版本被回滚"
        case .credentialRejected: return "凭据不正确"
        case .biometryUnavailable: return "此设备暂时无法使用生物识别"
        case .keychainFailure(let status): return "钥匙串操作失败（\(status)）"
        }
    }
}

/// 会在析构时清零并解锁内存页的字节容器。
/// 注意：Swift 仍可能在栈上产生临时副本，这是「尽力而为」的内存卫生，不是绝对保证。
public final class SecureBytes: @unchecked Sendable {
    private let storage: UnsafeMutableRawPointer
    public let count: Int

    public init(count: Int) {
        self.count = count
        storage = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 1)
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: count)
        #if canImport(Darwin)
        _ = mlock(storage, count)
        #endif
    }

    public init(_ bytes: some Collection<UInt8>) {
        let array = Array(bytes)
        count = array.count
        storage = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 1)
        array.withUnsafeBytes { source in
            storage.copyMemory(from: source.baseAddress!, byteCount: count)
        }
        #if canImport(Darwin)
        _ = mlock(storage, count)
        #endif
    }

    deinit {
        #if canImport(Darwin)
        memset_s(storage, count, 0, count)
        _ = munlock(storage, count)
        #else
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: count)
        #endif
        storage.deallocate()
    }

    public var bytes: [UInt8] {
        Array(UnsafeRawBufferPointer(start: storage, count: count))
    }

    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: storage, count: count))
    }

    public var symmetricKey: SymmetricKey {
        SymmetricKey(data: Data(bytes))
    }

    public static func random(count: Int = 32) throws -> SecureBytes {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw CryptoError.randomFailed }
        let secure = SecureBytes(bytes)
        for i in bytes.indices { bytes[i] = 0 }
        return secure
    }
}

public enum CryptoRandom {
    public static func bytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw CryptoError.randomFailed }
        return data
    }
}

/// 恒定时间比较，避免按字节提前返回泄露信息。
public func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<lhs.count {
        diff |= lhs[lhs.startIndex + i] ^ rhs[rhs.startIndex + i]
    }
    return diff == 0
}

// MARK: - KDF

public struct KDFParameters: Codable, Hashable, Sendable {
    public static let pbkdf2SHA256: UInt8 = 2
    /// Argon2id 预留槽位：格式已支持，算法实现可在不改文件格式的前提下替换。
    public static let argon2id: UInt8 = 1

    public var id: UInt8
    public var iterations: UInt32

    public init(id: UInt8 = KDFParameters.pbkdf2SHA256, iterations: UInt32) {
        self.id = id
        self.iterations = iterations
    }

    /// 主口令：600k 轮（OWASP 2023 对 PBKDF2-HMAC-SHA256 的建议值）。
    public static let standard = KDFParameters(iterations: 600_000)
    /// 恢复码熵很高，轮数可适当降低，兼顾解锁速度。
    public static let recovery = KDFParameters(iterations: 300_000)
    /// 仅供单元测试，切勿用于真实数据。
    public static let testing = KDFParameters(iterations: 1_000)
}

public enum KDF {
    public static func derive(passphrase: String,
                              salt: Data,
                              parameters: KDFParameters) throws -> SecureBytes {
        guard parameters.id == KDFParameters.pbkdf2SHA256 else {
            throw CryptoError.unsupportedKDF(parameters.id)
        }
        let password = Data(passphrase.precomposedStringWithCanonicalMapping.utf8)
        let key = SymmetricKey(data: password)
        var output = [UInt8]()
        var blockIndex: UInt32 = 1
        let rounds = max(1, Int(parameters.iterations))

        while output.count < 32 {
            var block = salt
            block.append(UInt8((blockIndex >> 24) & 0xFF))
            block.append(UInt8((blockIndex >> 16) & 0xFF))
            block.append(UInt8((blockIndex >> 8) & 0xFF))
            block.append(UInt8(blockIndex & 0xFF))

            var u = Array(HMAC<SHA256>.authenticationCode(for: block, using: key))
            var t = u
            if rounds > 1 {
                for _ in 1..<rounds {
                    u = Array(HMAC<SHA256>.authenticationCode(for: u, using: key))
                    for i in 0..<t.count { t[i] ^= u[i] }
                }
            }
            output.append(contentsOf: t)
            blockIndex += 1
            for i in u.indices { u[i] = 0 }
            for i in t.indices { t[i] = 0 }
        }
        let result = SecureBytes(output.prefix(32))
        for i in output.indices { output[i] = 0 }
        return result
    }

    public static func hkdf(inputKey: SecureBytes, salt: Data, info: String, count: Int = 32) -> SecureBytes {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey.symmetricKey,
            salt: salt,
            info: Data(info.utf8),
            outputByteCount: count
        )
        return derived.withUnsafeBytes { SecureBytes($0) }
    }
}

// MARK: - 恢复码（Crockford Base32）

public enum RecoveryKey {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// 15 字节 = 120 bit 熵 → 24 个字符，按 4 字符一组展示，便于抄写。
    /// 返回 24 个裸字符（不含分隔符）。分隔符只用于展示，绝不能参与密钥派生。
    public static func generate() throws -> String {
        let data = try CryptoRandom.bytes(15)
        return encode(data)
    }

    public static func format(_ raw: String) -> String {
        stride(from: 0, to: raw.count, by: 4).map { offset in
            let start = raw.index(raw.startIndex, offsetBy: offset)
            let end = raw.index(start, offsetBy: min(4, raw.count - offset))
            return String(raw[start..<end])
        }.joined(separator: "-")
    }

    /// 归一化：去掉分隔符、转大写、纠正易混字符（I/L→1，O→0）。
    public static func normalize(_ input: String) -> String? {
        var result = ""
        for character in input.uppercased() {
            switch character {
            case "0", "O": result.append("0")
            case "1", "I", "L": result.append("1")
            case " ", "-", "_", "\u{00A0}": continue
            default:
                guard alphabet.contains(character) else { return nil }
                result.append(character)
            }
        }
        guard result.count == 24 else { return nil }
        return result
    }

    static func encode(_ data: Data) -> String {
        var bits = 0
        var value = 0
        var output = ""
        for byte in data {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                let index = (value >> (bits - 5)) & 0x1F
                output.append(alphabet[index])
                bits -= 5
            }
        }
        if bits > 0 {
            let index = (value << (5 - bits)) & 0x1F
            output.append(alphabet[index])
        }
        return output
    }
}
