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
    }

    @Test func 不计统计流水两侧归零() {
        let tx = makeTransaction(kind: .expense, amount: 1_000)
        tx.isExcludedFromStats = true
        #expect(tx.statsExpenseMinorUnits == 0)
        #expect(tx.statsIncomeMinorUnits == 0)
    }
}
