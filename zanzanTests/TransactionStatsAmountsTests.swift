import Foundation
import Testing
@testable import zanzan

@MainActor
struct TransactionStatsAmountsTests {
    private func makeTransaction(kind: TransactionKind, amount: Int, fee: Int = 0) -> Transaction {
        let tx = Transaction(kind: kind, amountMinorUnits: amount, occurredAt: .now, ledgerID: UUID())
        tx.feeMinorUnits = fee
        return tx
    }

    @Test func 支出计支出不计收入() {
        let tx = makeTransaction(kind: .expense, amount: 1_000)
        #expect(tx.statsExpenseMinorUnits == 1_000)
        #expect(tx.statsIncomeMinorUnits == 0)
    }

    @Test func 收入计收入不计支出() {
        let tx = makeTransaction(kind: .income, amount: 2_000)
        #expect(tx.statsIncomeMinorUnits == 2_000)
        #expect(tx.statsExpenseMinorUnits == 0)
    }

    @Test func 转账手续费计入支出() {
        let tx = makeTransaction(kind: .transfer, amount: 10_000, fee: 50)
        #expect(tx.statsExpenseMinorUnits == 50)
        #expect(tx.statsIncomeMinorUnits == 0)
    }

    @Test func 报销到账不计收入() {
        let tx = makeTransaction(kind: .income, amount: 3_000)
        tx.settlementKindRawValue = TransactionLinkKind.reimbursement.rawValue
        #expect(tx.statsIncomeMinorUnits == 0)
        #expect(tx.statsExpenseMinorUnits == 0) // 报销到账不冲减支出（垫付支出照常计入）
    }

    @Test func 退款到账冲减支出不计收入() {
        let tx = makeTransaction(kind: .income, amount: 3_000)
        tx.settlementKindRawValue = TransactionLinkKind.refund.rawValue
        #expect(tx.statsIncomeMinorUnits == 0)
        #expect(tx.statsExpenseMinorUnits == -3_000) // 冲减支出而非计收入
    }

    @Test func 不计统计的退款到账不冲减() {
        let tx = makeTransaction(kind: .income, amount: 3_000)
        tx.settlementKindRawValue = TransactionLinkKind.refund.rawValue
        tx.isExcludedFromStats = true
        #expect(tx.statsExpenseMinorUnits == 0)
    }

    @Test func 不计统计流水两侧归零() {
        let tx = makeTransaction(kind: .expense, amount: 1_000)
        tx.isExcludedFromStats = true
        #expect(tx.statsExpenseMinorUnits == 0)
        #expect(tx.statsIncomeMinorUnits == 0)
    }

    // MARK: - 折算口径①（外币按自身汇率快照折本位币）

    private func makeForeign(
        kind: TransactionKind, amount: Int, fee: Int = 0, currency: String = "USD", rate: String? = "7.2"
    ) -> Transaction {
        let tx = makeTransaction(kind: kind, amount: amount, fee: fee)
        tx.currencyCode = currency
        tx.fxRateToBase = rate.map { Decimal(string: $0)! }
        return tx
    }

    @Test func 外币支出按自身快照折本位币() {
        let tx = makeForeign(kind: .expense, amount: 10_000) // USD 100.00 × 7.2
        #expect(tx.statsExpenseMinorUnits == 72_000)
        #expect(tx.statsIncomeMinorUnits == 0)
    }

    @Test func 外币收入按自身快照折本位币() {
        let tx = makeForeign(kind: .income, amount: 10_000)
        #expect(tx.statsIncomeMinorUnits == 72_000)
        #expect(tx.statsExpenseMinorUnits == 0)
    }

    @Test func 外币转账手续费折算后计入支出() {
        let tx = makeForeign(kind: .transfer, amount: 100_000, fee: 50)
        #expect(tx.statsExpenseMinorUnits == 360) // 50 × 7.2
        #expect(tx.statsFeeMinorUnits == 360)
    }

    @Test func 外币支出含手续费分别折算() {
        let tx = makeForeign(kind: .expense, amount: 10_000, fee: 100)
        #expect(tx.statsExpenseMinorUnits == 72_720)
        // 扣减口径自洽：statsExpense − statsFee 恰为折算后 amount
        #expect(tx.statsExpenseMinorUnits - tx.statsFeeMinorUnits == 72_000)
    }

    @Test func 外币退款到账冲减折算后支出() {
        let tx = makeForeign(kind: .income, amount: 3_000)
        tx.settlementKindRawValue = TransactionLinkKind.refund.rawValue
        #expect(tx.statsIncomeMinorUnits == 0)
        #expect(tx.statsExpenseMinorUnits == -21_600) // −3000 × 7.2
    }

    @Test func 外币报销到账两侧仍归零() {
        let tx = makeForeign(kind: .income, amount: 3_000)
        tx.settlementKindRawValue = TransactionLinkKind.reimbursement.rawValue
        #expect(tx.statsIncomeMinorUnits == 0)
        #expect(tx.statsExpenseMinorUnits == 0)
    }

    @Test func 外币无快照按一比一兜底() {
        let tx = makeForeign(kind: .expense, amount: 10_000, rate: nil) // 历史坏数据
        #expect(tx.statsExpenseMinorUnits == 10_000)
    }

    @Test func 不计统计外币流水手续费同归零() {
        let tx = makeForeign(kind: .expense, amount: 10_000, fee: 100)
        tx.isExcludedFromStats = true
        #expect(tx.statsExpenseMinorUnits == 0)
        #expect(tx.statsFeeMinorUnits == 0)
    }
}
