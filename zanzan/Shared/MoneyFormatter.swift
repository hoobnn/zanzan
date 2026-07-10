import Foundation

/// 金额分↔元换算唯一入口（设计文档 §4：全库不允许第二种实现）。
enum MoneyAmount {
    /// "12.34" → 1234；空串/非法/负数/超两位小数返回 nil。
    static func minorUnits(fromDecimalString string: String) -> Int? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-"),
              let decimal = Decimal(string: trimmed, locale: Locale(identifier: "en_US")) else { return nil }
        var scaled = decimal * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded == scaled else { return nil } // 超两位小数
        return (rounded as NSDecimalNumber).intValue
    }

    /// 允许负号的换算（账户期初余额等有符号场景）。
    static func signedMinorUnits(fromDecimalString string: String) -> Int? {
        var trimmed = string.trimmingCharacters(in: .whitespaces)
        var isNegative = false
        if trimmed.hasPrefix("-") {
            isNegative = true
            trimmed.removeFirst()
        }
        guard let magnitude = minorUnits(fromDecimalString: trimmed) else { return nil }
        return isNegative ? -magnitude : magnitude
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
