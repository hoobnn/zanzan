import Foundation

/// 记账键盘金额表达式：最多一个待定运算（base op current），完成/再按运算键时求值。
/// ponytail: 单级运算已覆盖键盘四运算符；链式多级运算需要时再扩展。
struct AmountExpression: Equatable {
    private(set) var base: String?
    private(set) var operatorSymbol: Character?
    private(set) var current: String

    init(decimalString: String = "") {
        current = decimalString
    }

    /// 键盘上方金额区展示串（不含货币符号）；空表达式显示 "0.00"。
    var displayText: String {
        if base == nil && current.isEmpty { return "0.00" }
        return (base ?? "") + (operatorSymbol.map(String.init) ?? "") + current
    }

    mutating func tapDigit(_ digit: Character) {
        if digit == "." {
            guard !current.contains(".") else { return }
            if current.isEmpty { current = "0" }
            current.append(".")
            return
        }
        guard digit.isNumber else { return }
        if let dotIndex = current.firstIndex(of: "."),
           current.distance(from: dotIndex, to: current.endIndex) > 2 { return } // 最多两位小数
        guard current.count < 12 else { return }
        current.append(digit)
    }

    mutating func tapBackspace() {
        if !current.isEmpty {
            current.removeLast()
        } else if operatorSymbol != nil {
            // 跨过运算符：还原为编辑 base
            current = base ?? ""
            base = nil
            operatorSymbol = nil
        }
    }

    /// 运算键（如「+ ×」）：正在编辑右操作数时先求值再挂新运算；
    /// 刚按过运算键时重按在主/副符号间切换（+ ↔ ×、− ↔ ÷）。
    mutating func tapOperator(primary: Character, secondary: Character) {
        if current.isEmpty {
            guard base != nil else { return }
            operatorSymbol = (operatorSymbol == primary) ? secondary : primary
            return
        }
        if base != nil { collapse() }
        guard !current.isEmpty else { return }
        base = current
        current = ""
        operatorSymbol = primary
    }

    /// 求值并返回十进制串（供 Draft 校验入库）；无法求值（如除零、负结果）返回空串。
    mutating func finalizedDecimalString() -> String {
        collapse()
        return current
    }

    /// 把 base op current 折叠进 current。结果四舍五入到两位小数；负数/除零视为非法清空。
    private mutating func collapse() {
        guard let lhsString = base, let operatorSymbol else { return }
        defer {
            base = nil
            self.operatorSymbol = nil
        }
        guard !current.isEmpty else {
            current = lhsString // 运算符悬空：丢弃运算符保留左操作数
            return
        }
        guard let lhs = Decimal(string: lhsString), let rhs = Decimal(string: current) else {
            current = ""
            return
        }
        let result: Decimal
        switch operatorSymbol {
        case "+": result = lhs + rhs
        case "-": result = lhs - rhs
        case "×": result = lhs * rhs
        case "÷":
            guard rhs != 0 else {
                current = ""
                return
            }
            result = lhs / rhs
        default:
            result = rhs
        }
        guard result >= 0 else {
            current = ""
            return
        }
        var rounded = Decimal()
        var mutableResult = result
        NSDecimalRound(&rounded, &mutableResult, 2, .plain)
        current = "\(rounded)"
    }
}
