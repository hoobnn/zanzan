import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct AssetsOverviewProviderTests {
    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    @Test func 净资产等于正余额减负余额且尊重计入开关() throws {
        let context = try makeContext()
        let card = Account(name: "储蓄卡", kind: .fund)
        card.initialBalanceMinorUnits = 10_000
        let credit = Account(name: "信用卡", kind: .credit)
        credit.initialBalanceMinorUnits = -15_300
        let excluded = Account(name: "不计入", kind: .fund)
        excluded.initialBalanceMinorUnits = 99_999
        excluded.isIncludedInNetWorth = false
        let deleted = Account(name: "已删", kind: .fund)
        deleted.initialBalanceMinorUnits = 88_888
        deleted.isSoftDeleted = true
        for account in [card, credit, excluded, deleted] { context.insert(account) }
        try context.save()

        let overview = try AssetsOverviewProvider(context: context).overview()

        #expect(overview.totalAssetsMinorUnits == 10_000)
        #expect(overview.totalLiabilitiesMinorUnits == 15_300)
        #expect(overview.netWorthMinorUnits == -5_300)
    }

    @Test func 借入取应付欠款借出取应收余额() throws {
        let context = try makeContext()
        let payable = Account(name: "欠同事", kind: .payable)
        payable.initialBalanceMinorUnits = -20_000
        let receivable = Account(name: "借给朋友", kind: .receivable)
        receivable.initialBalanceMinorUnits = 6_500
        for account in [payable, receivable] { context.insert(account) }
        try context.save()

        let overview = try AssetsOverviewProvider(context: context).overview()

        #expect(overview.borrowedTotalMinorUnits == 20_000)
        #expect(overview.lentTotalMinorUnits == 6_500)
    }

    @Test func 分组只含未归档账户且小计分列余额与欠款() throws {
        let context = try makeContext()
        let ledgerID = UUID()
        let debit = Account(name: "8888", kind: .fund)
        debit.initialBalanceMinorUnits = 10_000
        let overdrawn = Account(name: "9999", kind: .fund)
        overdrawn.initialBalanceMinorUnits = -15_300
        overdrawn.sortOrder = 1
        let archived = Account(name: "老卡", kind: .fund)
        archived.initialBalanceMinorUnits = 3_000
        archived.isArchived = true
        archived.sortOrder = 2
        for account in [debit, overdrawn, archived] { context.insert(account) }
        // 余额走流水派生：8888 支出 500 → 9500
        let expense = Transaction(kind: .expense, amountMinorUnits: 500, occurredAt: .now, ledgerID: ledgerID)
        expense.account = debit
        context.insert(expense)
        try context.save()

        let overview = try AssetsOverviewProvider(context: context).overview()

        #expect(overview.groups.count == 1)
        let group = try #require(overview.groups.first)
        #expect(group.kind == .fund)
        #expect(group.items.map(\.account.name) == ["8888", "9999"])
        #expect(group.items.first?.balanceMinorUnits == 9_500)
        #expect(group.balanceTotalMinorUnits == 9_500)
        #expect(group.debtTotalMinorUnits == 15_300)
        // 归档账户不进列表，但余额照常计入净资产
        #expect(overview.totalAssetsMinorUnits == 12_500)
    }
}
