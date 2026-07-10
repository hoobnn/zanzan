import Foundation
import Testing
@testable import zanzan

@MainActor
struct AmountExpressionTests {
    @Test func 空表达式显示占位() {
        #expect(AmountExpression().displayText == "0.00")
    }

    @Test func 小数最多两位且不允许双点() {
        var expression = AmountExpression()
        for character in "12.3.45" { expression.tapDigit(character) }
        #expect(expression.displayText == "12.34")
    }

    @Test func 首位小数点自动补零() {
        var expression = AmountExpression()
        expression.tapDigit(".")
        expression.tapDigit("5")
        #expect(expression.finalizedDecimalString() == "0.5")
    }

    @Test func 加法在完成时求值() {
        var expression = AmountExpression()
        for character in "12" { expression.tapDigit(character) }
        expression.tapOperator(primary: "+", secondary: "×")
        expression.tapDigit("3")
        #expect(expression.displayText == "12+3")
        #expect(expression.finalizedDecimalString() == "15")
    }

    @Test func 重按运算键切换为副符号() {
        var expression = AmountExpression()
        expression.tapDigit("6")
        expression.tapOperator(primary: "+", secondary: "×")
        expression.tapOperator(primary: "+", secondary: "×")
        expression.tapDigit("7")
        #expect(expression.finalizedDecimalString() == "42")
    }

    @Test func 连续运算先折叠前一段() {
        var expression = AmountExpression()
        expression.tapDigit("2")
        expression.tapOperator(primary: "+", secondary: "×")
        expression.tapDigit("3")
        expression.tapOperator(primary: "-", secondary: "÷")
        expression.tapDigit("1")
        #expect(expression.displayText == "5-1")
        #expect(expression.finalizedDecimalString() == "4")
    }

    @Test func 退格跨运算符还原左操作数() {
        var expression = AmountExpression()
        expression.tapDigit("8")
        expression.tapOperator(primary: "+", secondary: "×")
        expression.tapBackspace()
        #expect(expression.displayText == "8")
        expression.tapBackspace()
        #expect(expression.displayText == "0.00")
    }

    @Test func 除零与负结果视为非法() {
        var dividedByZero = AmountExpression()
        dividedByZero.tapDigit("9")
        dividedByZero.tapOperator(primary: "-", secondary: "÷")
        dividedByZero.tapOperator(primary: "-", secondary: "÷") // 切到 ÷
        dividedByZero.tapDigit("0")
        #expect(dividedByZero.finalizedDecimalString() == "")

        var negative = AmountExpression()
        negative.tapDigit("1")
        negative.tapOperator(primary: "-", secondary: "÷")
        negative.tapDigit("5")
        #expect(negative.finalizedDecimalString() == "")
    }

    @Test func 除法结果四舍五入到两位() {
        var expression = AmountExpression()
        for character in "10" { expression.tapDigit(character) }
        expression.tapOperator(primary: "-", secondary: "÷")
        expression.tapOperator(primary: "-", secondary: "÷")
        expression.tapDigit("3")
        #expect(expression.finalizedDecimalString() == "3.33")
    }

    @Test func 编辑态用既有金额初始化() {
        var expression = AmountExpression(decimalString: "12.34")
        #expect(expression.displayText == "12.34")
        #expect(expression.finalizedDecimalString() == "12.34")
    }
}
