import Foundation
import Testing
@testable import zanzan

@MainActor
struct TransactionDerivationTests {
    private func makeTransaction(kind: TransactionKind, amount: Int) -> Transaction {
        Transaction(kind: kind, amountMinorUnits: amount, occurredAt: .now, ledgerID: UUID())
    }

    @Test func 符号金额支出负收入正转账零() {
        #expect(makeTransaction(kind: .expense, amount: 2500).signedMinorUnits == -2500)
        #expect(makeTransaction(kind: .income, amount: 8800).signedMinorUnits == 8800)
        #expect(makeTransaction(kind: .transfer, amount: 100).signedMinorUnits == 0)
    }

    @Test func 未知类型符号金额为零() {
        let txn = makeTransaction(kind: .expense, amount: 100)
        txn.kindRawValue = "cryptoStaking"
        #expect(txn.signedMinorUnits == 0)
    }

    @Test func 支出余额口径含手续费() {
        let account = Account(name: "卡", kind: .fund)
        let txn = makeTransaction(kind: .expense, amount: 2500)
        txn.account = account
        txn.feeMinorUnits = 100
        #expect(txn.balanceDeltaMinorUnits(for: account.uuid) == -2600)
        #expect(txn.balanceDeltaMinorUnits(for: UUID()) == 0) // 无关账户
    }

    @Test func 收入余额口径扣手续费() {
        let account = Account(name: "卡", kind: .fund)
        let txn = makeTransaction(kind: .income, amount: 5000)
        txn.account = account
        txn.feeMinorUnits = 100 // fee 恒为流出：income delta = amount − fee
        #expect(txn.balanceDeltaMinorUnits(for: account.uuid) == 4900)
    }

    @Test func 转账余额口径转出含费转入按到账金额() {
        let source = Account(name: "招行", kind: .fund)
        let target = Account(name: "美元户", kind: .fund)
        let txn = makeTransaction(kind: .transfer, amount: 72000)
        txn.account = source
        txn.targetAccount = target
        txn.feeMinorUnits = 500
        txn.targetAmountMinorUnits = 10000 // 跨币种到账金额
        #expect(txn.balanceDeltaMinorUnits(for: source.uuid) == -72500)
        #expect(txn.balanceDeltaMinorUnits(for: target.uuid) == 10000)
    }

    @Test func 同币种转账转入按转出金额() {
        let source = Account(name: "招行", kind: .fund)
        let target = Account(name: "现金", kind: .fund)
        let txn = makeTransaction(kind: .transfer, amount: 30000)
        txn.account = source
        txn.targetAccount = target
        #expect(txn.balanceDeltaMinorUnits(for: target.uuid) == 30000)
    }

    @Test func 未知类型不影响余额() {
        let account = Account(name: "卡", kind: .fund)
        let txn = makeTransaction(kind: .expense, amount: 100)
        txn.account = account
        txn.kindRawValue = "cryptoStaking"
        #expect(txn.balanceDeltaMinorUnits(for: account.uuid) == 0)
    }
}
