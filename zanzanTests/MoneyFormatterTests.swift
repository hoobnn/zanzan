import Foundation
import Testing
@testable import zanzan

@MainActor
struct MoneyFormatterTests {
    @Test func 十进制串转分() {
        #expect(MoneyAmount.minorUnits(fromDecimalString: "12.34") == 1234)
        #expect(MoneyAmount.minorUnits(fromDecimalString: "0.5") == 50)
        #expect(MoneyAmount.minorUnits(fromDecimalString: "12") == 1200)
        #expect(MoneyAmount.minorUnits(fromDecimalString: " 8.00 ") == 800)
    }

    @Test func 非法输入返回nil() {
        #expect(MoneyAmount.minorUnits(fromDecimalString: "abc") == nil)
        #expect(MoneyAmount.minorUnits(fromDecimalString: "1.234") == nil) // 超两位小数
        #expect(MoneyAmount.minorUnits(fromDecimalString: "-5") == nil)   // 无符号入口拒负数
        #expect(MoneyAmount.minorUnits(fromDecimalString: "") == nil)
    }

    @Test func 严格解析拒绝宽松截断输入() {
        #expect(MoneyAmount.minorUnits(fromDecimalString: "1,234.56") == nil) // 千分位逗号
        #expect(MoneyAmount.minorUnits(fromDecimalString: "12..3") == nil)    // 多小数点
        #expect(MoneyAmount.minorUnits(fromDecimalString: "12.34abc") == nil) // 尾随字母
        #expect(MoneyAmount.minorUnits(fromDecimalString: "1e3") == nil)      // 科学计数法
        #expect(MoneyAmount.minorUnits(fromDecimalString: ".") == nil)        // 无数字
        #expect(MoneyAmount.signedMinorUnits(fromDecimalString: "--5") == nil) // 双负号
        #expect(MoneyAmount.signedMinorUnits(fromDecimalString: "1e3") == nil)
    }

    @Test func 量级上限两侧() {
        // 上限 = maxAbsoluteMinorUnits（10^15 分 = 10^13 元），恰达上限接受、超一分拒绝
        #expect(MoneyAmount.minorUnits(fromDecimalString: "10000000000000") == 1_000_000_000_000_000)
        #expect(MoneyAmount.minorUnits(fromDecimalString: "10000000000000.01") == nil)
        #expect(MoneyAmount.signedMinorUnits(fromDecimalString: "-10000000000000") == -1_000_000_000_000_000)
        #expect(MoneyAmount.signedMinorUnits(fromDecimalString: "-10000000000000.01") == nil)
        // 旧实现的 Int 环绕样本：绕过负号检查环绕成 Int.min / 20 位纯数字环绕成正数垃圾值
        #expect(MoneyAmount.minorUnits(fromDecimalString: "92233720368547758.08") == nil)
        #expect(MoneyAmount.minorUnits(fromDecimalString: "99999999999999999999") == nil)
    }

    @Test func 带符号入口允许负数() {
        #expect(MoneyAmount.signedMinorUnits(fromDecimalString: "-5") == -500)
        #expect(MoneyAmount.signedMinorUnits(fromDecimalString: "3.5") == 350)
        #expect(MoneyAmount.signedMinorUnits(fromDecimalString: "-") == nil)
    }

    @Test func 合法路径回归() {
        #expect(MoneyAmount.minorUnits(fromDecimalString: "25.50") == 2550)
        #expect(MoneyAmount.minorUnits(fromDecimalString: "0.10") == 10)
        #expect(MoneyAmount.minorUnits(fromDecimalString: ".5") == 50)
        #expect(MoneyAmount.signedMinorUnits(fromDecimalString: "-500") == -50000)
    }

    @Test func 严格Decimal解析供汇率复用() {
        #expect(MoneyAmount.strictDecimal(from: "6.8912") == Decimal(string: "6.8912"))
        #expect(MoneyAmount.strictDecimal(from: "1,234.56") == nil)
        #expect(MoneyAmount.strictDecimal(from: "1e3") == nil)
        #expect(MoneyAmount.strictDecimal(from: "-6.89") == nil) // 默认拒负号
        #expect(MoneyAmount.strictDecimal(from: "-6.89", allowNegative: true) == Decimal(string: "-6.89"))
    }

    @Test func 分转十进制串回填() {
        #expect(MoneyAmount.decimalString(fromMinorUnits: 1234) == "12.34")
        #expect(MoneyAmount.decimalString(fromMinorUnits: 1200) == "12")
        #expect(MoneyAmount.decimalString(fromMinorUnits: -350) == "-3.5")
    }

    @Test func 展示格式化跟随应用语言() {
        #expect(formatAmount(1234, language: .simplifiedChinese) == "¥12.34")
        #expect(formatAmount(-1234, language: .simplifiedChinese) == "-¥12.34")
        #expect(formatAmount(1234, withSign: true, language: .simplifiedChinese) == "+¥12.34")
        #expect(formatAmount(0, language: .simplifiedChinese) == "¥0.00")
        #expect(formatAmount(1234, language: .english) == "CN¥12.34")
    }
}
