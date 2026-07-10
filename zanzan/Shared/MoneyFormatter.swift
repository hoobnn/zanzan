import Foundation

/// 金额分↔元换算唯一入口（设计文档 §4：全库不允许第二种实现）。
enum MoneyAmount {
    /// 单笔金额量级上限（分）：10^15 分 = 百亿元级。超限拒绝，
    /// 防 `NSDecimalNumber.intValue` 越界环绕（如 "92233720368547758.08" 环绕成 Int.min）。
    static let maxAbsoluteMinorUnits = 1_000_000_000_000_000

    /// 严格十进制解析：仅 ASCII 数字 + 至多一个小数点（且至少含一位数字）；
    /// `allowNegative` 时额外允许一个前导负号。拒绝千分位逗号、科学计数法、
    /// 尾随字母、多小数点等 `Decimal(string:)` 会静默截断的输入；定点解析不经 Double。
    static func strictDecimal(from string: String, allowNegative: Bool = false) -> Decimal? {
        var digits = string.trimmingCharacters(in: .whitespaces)
        var isNegative = false
        if allowNegative, digits.hasPrefix("-") {
            isNegative = true
            digits.removeFirst()
        }
        guard digits.allSatisfy({ ("0"..."9").contains($0) || $0 == "." }),
              digits.contains(where: { ("0"..."9").contains($0) }),
              digits.filter({ $0 == "." }).count <= 1,
              let magnitude = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }
        return isNegative ? -magnitude : magnitude
    }

    /// "12.34" → 1234；空串/非法/负数/超两位小数/超量级上限返回 nil。
    static func minorUnits(fromDecimalString string: String) -> Int? {
        guard let decimal = strictDecimal(from: string) else { return nil }
        return minorUnits(scaling: decimal)
    }

    /// 允许负号的换算（账户期初余额等有符号场景）。
    static func signedMinorUnits(fromDecimalString string: String) -> Int? {
        guard let decimal = strictDecimal(from: string, allowNegative: true) else { return nil }
        return minorUnits(scaling: decimal)
    }

    /// 元 Decimal → 分：超两位小数或绝对值超 `maxAbsoluteMinorUnits` 返回 nil。
    private static func minorUnits(scaling decimal: Decimal) -> Int? {
        var scaled = decimal * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded == scaled else { return nil } // 超两位小数
        guard abs(rounded) <= Decimal(maxAbsoluteMinorUnits) else { return nil } // 越界防环绕
        return (rounded as NSDecimalNumber).intValue
    }

    /// 表单回填用十进制串（无货币符号，尾零自然省略）。
    static func decimalString(fromMinorUnits minorUnits: Int) -> String {
        "\(Decimal(minorUnits) / 100)"
    }
}

/// 金额展示格式化唯一入口（设计文档 §4）。本位币锁 CNY、locale 锁 zh_CN（测试确定性）。
func formatAmount(_ minorUnits: Int, withSign: Bool = false) -> String {
    let decimal = Decimal(minorUnits) / 100
    let core = decimal.formatted(.currency(code: "CNY").locale(Locale(identifier: "zh_CN")))
    if withSign && minorUnits > 0 { return "+\(core)" }
    return core
}
