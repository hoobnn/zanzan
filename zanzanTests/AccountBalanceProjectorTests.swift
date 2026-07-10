import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct AccountBalanceProjectorTests {
    @Test func 余额等于期初加流水派生() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let ledgerID = UUID()
        let cash = StoredAccount(name: "现金", kind: .fund)
        cash.initialBalanceMinorUnits = 10_000
        let card = StoredAccount(name: "储蓄卡", kind: .fund)
        context.insert(cash)
        context.insert(card)

        let expense = StoredTransaction(kind: .expense, amountMinorUnits: 1_000, occurredAt: .now, ledgerID: ledgerID)
        expense.account = cash
        let income = StoredTransaction(kind: .income, amountMinorUnits: 5_000, occurredAt: .now, ledgerID: ledgerID)
        income.account = cash
        income.feeMinorUnits = 100 // income − fee 口径
        let transfer = StoredTransaction(kind: .transfer, amountMinorUnits: 2_000, occurredAt: .now, ledgerID: ledgerID)
        transfer.account = cash
        transfer.targetAccount = card
        transfer.feeMinorUnits = 50
        let deleted = StoredTransaction(kind: .expense, amountMinorUnits: 9_999, occurredAt: .now, ledgerID: ledgerID)
        deleted.account = cash
        deleted.isSoftDeleted = true // 软删流水不计
        for tx in [expense, income, transfer, deleted] { context.insert(tx) }
        try context.save()

        let projector = AccountBalanceProjector(context: context)
        // 现金：10000 − 1000 + (5000−100) − (2000+50) = 11850
        let cashBalance = try projector.balanceMinorUnits(of: cash)
        // 储蓄卡：0 + 2000 = 2000
        let cardBalance = try projector.balanceMinorUnits(of: card)
        #expect(cashBalance == 11_850)
        #expect(cardBalance == 2_000)
    }
}
