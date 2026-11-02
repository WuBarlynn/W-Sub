import Foundation

/// 金额以「最小货币单位」整数存储，永不使用 Double。
/// 例如 ¥88.00 → 8800；¥1500（JPY，无小数位）→ 1500。
public struct Money: Codable, Hashable, Sendable, Comparable {
    public var minorUnits: Int64
    public var currencyCode: String

    public init(minorUnits: Int64, currencyCode: String) {
        self.minorUnits = minorUnits
        self.currencyCode = currencyCode.uppercased()
    }

    public init?(decimal: Decimal, currencyCode: String) {
        self.currencyCode = currencyCode.uppercased()
        let digits = CurrencyExponent.digits(for: self.currencyCode)
        var scaled = decimal * Decimal(sign: .plus, exponent: digits, significand: 1)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard let value = Int64(exactly: NSDecimalNumber(decimal: rounded)) else { return nil }
        self.minorUnits = value
    }

    public static func zero(_ currencyCode: String) -> Money {
        Money(minorUnits: 0, currencyCode: currencyCode)
    }

    public var fractionDigits: Int { CurrencyExponent.digits(for: currencyCode) }

    /// 精确的十进制值（用于统计与折算，不用于展示）。
    public var decimal: Decimal {
        Decimal(sign: .plus, exponent: -fractionDigits, significand: Decimal(minorUnits))
    }

    public var isZero: Bool { minorUnits == 0 }

    public func formatted(locale: Locale = .autoupdatingCurrent) -> String {
        decimal.formatted(.currency(code: currencyCode).locale(locale))
    }

    /// 去掉货币符号的纯数字，用于输入框回填。
    public var plainString: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = fractionDigits
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSDecimalNumber(decimal: decimal)) ?? "\(decimal)"
    }

    // MARK: - 运算（币种必须一致，跨币种需先显式换算）

    public static func + (lhs: Money, rhs: Money) -> Money {
        precondition(lhs.currencyCode == rhs.currencyCode, "不同币种不能直接相加，请先换算")
        return Money(minorUnits: lhs.minorUnits + rhs.minorUnits, currencyCode: lhs.currencyCode)
    }

    public static func - (lhs: Money, rhs: Money) -> Money {
        precondition(lhs.currencyCode == rhs.currencyCode, "不同币种不能直接相减，请先换算")
        return Money(minorUnits: lhs.minorUnits - rhs.minorUnits, currencyCode: lhs.currencyCode)
    }

    public static func < (lhs: Money, rhs: Money) -> Bool {
        precondition(lhs.currencyCode == rhs.currencyCode)
        return lhs.minorUnits < rhs.minorUnits
    }

    public func multiplied(by factor: Decimal) -> Money {
        Money(decimal: decimal * factor, currencyCode: currencyCode) ?? self
    }

    public func converting(to code: String, rate: Decimal) -> Money {
        Money(decimal: decimal * rate, currencyCode: code) ?? Money(minorUnits: 0, currencyCode: code)
    }

    /// 显示用的「月均」等折算值：保留到分，四舍五入。
    public func rounded() -> Money {
        Money(decimal: decimal, currencyCode: currencyCode) ?? self
    }
}

public enum CurrencyExponent {
    private static let zero: Set<String> = ["JPY", "KRW", "VND", "CLP", "ISK", "PYG", "XAF", "XOF", "XPF", "UGX", "RWF"]
    private static let three: Set<String> = ["BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"]

    public static func digits(for code: String) -> Int {
        let upper = code.uppercased()
        if zero.contains(upper) { return 0 }
        if three.contains(upper) { return 3 }
        return 2
    }
}
