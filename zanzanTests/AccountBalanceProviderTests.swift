import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct AccountBalanceProviderTests {
    @Test func 余额等于期初加流水派生() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let ledgerID = UUID()
        let cash = Account(name: "现金", kind: .fund)
        cash.initialBalanceMinorUnits = 10_000
        let card = Account(name: "储蓄卡", kind: .fund)
        context.insert(cash)
        context.insert(card)

        let expense = Transaction(kind: .expense, amountMinorUnits: 1_000, occurredAt: .now, ledgerID: ledgerID)
        expense.account = cash
        let income = Transaction(kind: .income, amountMinorUnits: 5_000, occurredAt: .now, ledgerID: ledgerID)
        income.account = cash
        income.feeMinorUnits = 100 // income − fee 口径
        let transfer = Transaction(kind: .transfer, amountMinorUnits: 2_000, occurredAt: .now, ledgerID: ledgerID)
        transfer.account = cash
        transfer.targetAccount = card
        transfer.feeMinorUnits = 50
        let deleted = Transaction(kind: .expense, amountMinorUnits: 9_999, occurredAt: .now, ledgerID: ledgerID)
        deleted.account = cash
        deleted.isSoftDeleted = true // 软删流水不计
        for tx in [expense, income, transfer, deleted] { context.insert(tx) }
        try context.save()

        let projector = AccountBalanceProvider(context: context)
        // 现金：10000 − 1000 + (5000−100) − (2000+50) = 11850
        let cashBalance = try projector.balanceMinorUnits(of: cash)
        // 储蓄卡：0 + 2000 = 2000
        let cardBalance = try projector.balanceMinorUnits(of: card)
        #expect(cashBalance == 11_850)
        #expect(cardBalance == 2_000)
    }

    @Test func asOf之后的未来流水不计入时点余额() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let account = Account(name: "现金", kind: .fund)
        account.initialBalanceMinorUnits = 10_000
        context.insert(account)
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)

        let past = Transaction(
            kind: .expense,
            amountMinorUnits: 1_000,
            occurredAt: asOf.addingTimeInterval(-60),
            ledgerID: UUID()
        )
        past.account = account
        let future = Transaction(
            kind: .income,
            amountMinorUnits: 5_000,
            occurredAt: asOf.addingTimeInterval(60),
            ledgerID: UUID()
        )
        future.account = account
        context.insert(past)
        context.insert(future)
        try context.save()

        let provider = AccountBalanceProvider(context: context)
        #expect(try provider.balanceMinorUnits(of: account, asOf: asOf) == 9_000)
        #expect(try provider.balanceMinorUnits(of: account, asOf: future.occurredAt) == 14_000)
    }

    @Test func 有快照时使用最新快照加后续流水() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let account = Account(name: "现金", kind: .fund)
        account.initialBalanceMinorUnits = 10_000
        context.insert(account)
        let snapshotAt = Date(timeIntervalSince1970: 1_800_000_000)
        context.insert(BalanceSnapshot(
            accountID: account.uuid,
            snapshotAt: snapshotAt,
            balanceMinorUnits: 9_000
        ))
        let later = Transaction(
            kind: .income,
            amountMinorUnits: 2_000,
            occurredAt: snapshotAt.addingTimeInterval(60),
            ledgerID: UUID()
        )
        later.account = account
        context.insert(later)
        try context.save()

        let provider = AccountBalanceProvider(context: context)
        #expect(
            try provider.balanceMinorUnits(of: account, asOf: later.occurredAt)
                == 11_000
        )
        #expect(
            try provider.fullyDerivedBalanceMinorUnits(of: account, asOf: later.occurredAt)
                == 12_000
        )
    }

    @Test func 余额聚合溢出抛MoneyArithmeticError而非崩溃() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let account = Account(name: "极值账户", kind: .fund)
        account.initialBalanceMinorUnits = Int.max
        context.insert(account)
        let income = Transaction(
            kind: .income,
            amountMinorUnits: 1,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            ledgerID: UUID()
        )
        income.account = account
        context.insert(income)
        try context.save()

        #expect(throws: MoneyArithmeticError.self) {
            try AccountBalanceProvider(context: context)
                .balanceMinorUnits(of: account, asOf: income.occurredAt)
        }
    }
}
