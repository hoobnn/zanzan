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

    @Test func 带符号入口允许负数() {
        #expect(MoneyAmount.signedMinorUnits(fromDecimalString: "-5") == -500)
        #expect(MoneyAmount.signedMinorUnits(fromDecimalString: "3.5") == 350)
        #expect(MoneyAmount.signedMinorUnits(fromDecimalString: "-") == nil)
    }

    @Test func 分转十进制串回填() {
        #expect(MoneyAmount.decimalString(fromMinorUnits: 1234) == "12.34")
        #expect(MoneyAmount.decimalString(fromMinorUnits: 1200) == "12")
        #expect(MoneyAmount.decimalString(fromMinorUnits: -350) == "-3.5")
    }

    @Test func 展示格式化锁定zhCN人民币() {
        #expect(formatAmount(1234) == "¥12.34")
        #expect(formatAmount(-1234) == "-¥12.34")
        #expect(formatAmount(1234, withSign: true) == "+¥12.34")
        #expect(formatAmount(0) == "¥0.00")
    }
}
