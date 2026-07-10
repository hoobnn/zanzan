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

    @Test func 溢缴应付账户总借入与分组小计同口径() throws {
        let context = try makeContext()
        let owed = Account(name: "欠同事", kind: .payable)
        owed.initialBalanceMinorUnits = -20_000
        let overpaid = Account(name: "溢缴花呗", kind: .payable)
        overpaid.initialBalanceMinorUnits = 5_000 // 溢缴：正余额不抵减欠款
        overpaid.sortOrder = 1
        for account in [owed, overpaid] { context.insert(account) }
        try context.save()

        let overview = try AssetsOverviewProvider(context: context).overview()

        #expect(overview.borrowedTotalMinorUnits == 20_000) // 非净额 15_000
        let group = try #require(overview.groups.first { $0.kind == .payable })
        #expect(group.debtTotalMinorUnits == 20_000) // 顶部与分组同一个数
        #expect(group.balanceTotalMinorUnits == 5_000)
    }

    // MARK: - 折算口径②（净资产按该币种全库最近快照折算）

    /// 直接构造外币流水（并行代理正在加 Draft 外币字段，测试不依赖在途 API）
    @discardableResult
    private func insertForeignTransaction(
        _ context: ModelContext, kind: TransactionKind, amount: Int,
        account: Account, ledgerID: UUID, day: Int, rate: String
    ) -> Transaction {
        let tx = Transaction(
            kind: kind, amountMinorUnits: amount,
            // 固定用过去月份：汇率字典按 occurredAt <= asOf(.now) 取最近，未来日期会被正确排除
            occurredAt: Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: day))!,
            ledgerID: ledgerID
        )
        tx.account = account
        tx.currencyCode = "USD"
        tx.fxRateToBase = Decimal(string: rate)!
        context.insert(tx)
        return tx
    }

    @Test func 净资产按最近快照折算而收支统计按各自快照() throws {
        let context = try makeContext()
        let ledgerID = UUID()
        let usd = Account(name: "美元卡", kind: .fund)
        usd.currencyCode = "USD"
        usd.initialBalanceMinorUnits = 10_000
        context.insert(usd)
        // 旧流水快照 7.0，新流水快照 7.3 → 全库最近快照为 7.3
        insertForeignTransaction(context, kind: .income, amount: 10_000, account: usd, ledgerID: ledgerID, day: 1, rate: "7.0")
        insertForeignTransaction(context, kind: .expense, amount: 5_000, account: usd, ledgerID: ledgerID, day: 15, rate: "7.3")
        try context.save()

        // 口径②：余额（原币 15_000 分）整体按最近快照 7.3 折算——旧余额也用新快照
        let overview = try AssetsOverviewProvider(context: context).overview()
        #expect(overview.totalAssetsMinorUnits == 109_500) // 15_000 × 7.3（≠ 15_000 × 7.0）
        #expect(overview.netWorthMinorUnits == 109_500)
        #expect(overview.groups.first?.balanceTotalMinorUnits == 109_500) // 组小计同口径
        #expect(overview.groups.first?.items.first?.balanceMinorUnits == 15_000) // 单账户保持原币
        #expect(overview.fxRatesByCurrency == ["USD": Decimal(string: "7.3")!])
        #expect(overview.fxFallbackCurrencyCodes.isEmpty)

        // 口径①对照：同月收支统计按流水各自快照（收入 7.0、支出 7.3），历史口径永固
        let stats = try MonthlyStatsProvider(context: context).stats(ledgerID: ledgerID, year: 2026, month: 6)
        #expect(stats.incomeTotalMinorUnits == 70_000) // 10_000 × 7.0，不随最近快照 7.3 改写
        #expect(stats.expenseTotalMinorUnits == 36_500) // 5_000 × 7.3
    }

    @Test func 无快照币种按一比一兜底并披露() throws {
        let context = try makeContext()
        let jpy = Account(name: "日元卡", kind: .fund)
        jpy.currencyCode = "JPY"
        jpy.initialBalanceMinorUnits = 5_000 // 无任何 JPY 流水快照
        context.insert(jpy)
        try context.save()

        let overview = try AssetsOverviewProvider(context: context).overview()
        #expect(overview.totalAssetsMinorUnits == 5_000) // 1:1 兜底
        #expect(overview.fxFallbackCurrencyCodes == ["JPY"])
        #expect(overview.fxRatesByCurrency.isEmpty)
    }
}
