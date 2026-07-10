import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct MonthlyStatsProviderTests {
    private struct Env {
        let context: ModelContext
        let ledgerID: UUID
        let accountUUID: UUID
    }

    private func makeEnv() throws -> Env {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let ledger = try LedgerService(context: context).createLedger(LedgerDraft(name: "测试账本"))
        var accountDraft = AccountDraft()
        accountDraft.name = "现金"
        let account = try AccountService(context: context).createAccount(accountDraft)
        return Env(context: context, ledgerID: ledger.uuid, accountUUID: account.uuid)
    }

    private func makeCategory(
        _ env: Env, name: String, kind: TransactionKind = .expense, parentID: UUID? = nil
    ) throws -> Category {
        var draft = CategoryDraft()
        draft.name = name
        draft.kind = kind
        draft.parentID = parentID
        return try CategoryService(context: env.context).createCategory(draft)
    }

    @discardableResult
    private func record(
        _ env: Env, kind: TransactionKind, amount: String, categoryUUID: UUID?, day: Int, month: Int = 7
    ) throws -> Transaction {
        var draft = TransactionDraft()
        draft.kind = kind
        draft.amountString = amount
        draft.accountUUID = env.accountUUID
        draft.categoryUUID = categoryUUID
        draft.occurredAt = Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day))!
        return try TransactionService(context: env.context).recordTransaction(draft, ledgerID: env.ledgerID)
    }

    @Test func 月收支汇总只算当月当账本() throws {
        let env = try makeEnv()
        let food = try makeCategory(env, name: "餐饮")
        let salary = try makeCategory(env, name: "工资", kind: .income)
        try record(env, kind: .expense, amount: "100", categoryUUID: food.uuid, day: 5)
        try record(env, kind: .income, amount: "5000", categoryUUID: salary.uuid, day: 10)
        try record(env, kind: .expense, amount: "999", categoryUUID: food.uuid, day: 5, month: 6) // 上月

        let stats = try MonthlyStatsProvider(context: env.context)
            .stats(ledgerID: env.ledgerID, year: 2026, month: 7)
        #expect(stats.expenseTotalMinorUnits == 10_000)
        #expect(stats.incomeTotalMinorUnits == 500_000)
    }

    @Test func 二级金额汇入父类且并列展示() throws {
        let env = try makeEnv()
        let dining = try makeCategory(env, name: "餐饮")
        let breakfast = try makeCategory(env, name: "早餐", parentID: dining.uuid)
        let lunch = try makeCategory(env, name: "午餐", parentID: dining.uuid)
        try record(env, kind: .expense, amount: "10", categoryUUID: dining.uuid, day: 1) // 父直挂
        try record(env, kind: .expense, amount: "20", categoryUUID: breakfast.uuid, day: 2)
        try record(env, kind: .expense, amount: "30", categoryUUID: lunch.uuid, day: 3)

        let stats = try MonthlyStatsProvider(context: env.context)
            .stats(ledgerID: env.ledgerID, year: 2026, month: 7)
        let diningStat = stats.expenseRanking.first { $0.category.uuid == dining.uuid }!
        #expect(diningStat.directMinorUnits == 1_000)
        #expect(diningStat.totalMinorUnits == 6_000)
        #expect(diningStat.children.map(\.amountMinorUnits) == [3_000, 2_000]) // 子类降序
    }

    @Test func 排行按总额降序() throws {
        let env = try makeEnv()
        let dining = try makeCategory(env, name: "餐饮")
        let transport = try makeCategory(env, name: "交通")
        try record(env, kind: .expense, amount: "10", categoryUUID: dining.uuid, day: 1)
        try record(env, kind: .expense, amount: "50", categoryUUID: transport.uuid, day: 2)

        let stats = try MonthlyStatsProvider(context: env.context)
            .stats(ledgerID: env.ledgerID, year: 2026, month: 7)
        #expect(stats.expenseRanking.map(\.category.name) == ["交通", "餐饮"])
    }

    @Test func 转账手续费计入支出与fee口径() throws {
        let env = try makeEnv()
        var targetDraft = AccountDraft()
        targetDraft.name = "储蓄卡"
        let target = try AccountService(context: env.context).createAccount(targetDraft)
        var draft = TransactionDraft()
        draft.kind = .transfer
        draft.amountString = "1000"
        draft.feeString = "5"
        draft.accountUUID = env.accountUUID
        draft.targetAccountUUID = target.uuid
        draft.occurredAt = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 8))!
        try TransactionService(context: env.context).recordTransaction(draft, ledgerID: env.ledgerID)

        let stats = try MonthlyStatsProvider(context: env.context)
            .stats(ledgerID: env.ledgerID, year: 2026, month: 7)
        #expect(stats.expenseTotalMinorUnits == 500)
        #expect(stats.feeTotalMinorUnits == 500)
        #expect(stats.expenseRanking.isEmpty) // fee 无分类归属，不进排行
    }

    @Test func 不计统计流水被剔除() throws {
        let env = try makeEnv()
        let food = try makeCategory(env, name: "餐饮")
        let tx = try record(env, kind: .expense, amount: "100", categoryUUID: food.uuid, day: 5)
        tx.isExcludedFromStats = true
        try env.context.save()

        let stats = try MonthlyStatsProvider(context: env.context)
            .stats(ledgerID: env.ledgerID, year: 2026, month: 7)
        #expect(stats.expenseTotalMinorUnits == 0)
        #expect(stats.expenseRanking.isEmpty)
    }

    @Test func 未知kind流水从精确统计剔除() throws {
        let env = try makeEnv()
        let food = try makeCategory(env, name: "餐饮")
        let tx = try record(env, kind: .expense, amount: "100", categoryUUID: food.uuid, day: 5)
        tx.kindRawValue = "future_kind" // §4 前向兼容：语义未知整笔剔除（含 fee）
        tx.feeMinorUnits = 50
        try env.context.save()

        let stats = try MonthlyStatsProvider(context: env.context)
            .stats(ledgerID: env.ledgerID, year: 2026, month: 7)
        #expect(stats.expenseTotalMinorUnits == 0)
        #expect(stats.incomeTotalMinorUnits == 0)
        #expect(stats.feeTotalMinorUnits == 0)
        #expect(stats.expenseRanking.isEmpty)
    }

    // MARK: - 折算口径①（外币按自身汇率快照折本位币，历史口径永固）

    /// 直接改模型标外币（并行代理正在加 Draft 外币字段，测试不依赖在途 API）
    private func markForeign(_ tx: Transaction, currency: String = "USD", rate: String) throws {
        tx.currencyCode = currency
        tx.fxRateToBase = Decimal(string: rate)!
        try tx.modelContext?.save()
    }

    @Test func 同月混币汇总按各自快照折本位币() throws {
        let env = try makeEnv()
        let food = try makeCategory(env, name: "餐饮")
        try record(env, kind: .expense, amount: "100", categoryUUID: food.uuid, day: 5) // CNY 10_000 分
        let usd = try record(env, kind: .expense, amount: "100", categoryUUID: food.uuid, day: 6)
        try markForeign(usd, rate: "7.2") // USD 10_000 分 → 72_000 分

        let stats = try MonthlyStatsProvider(context: env.context)
            .stats(ledgerID: env.ledgerID, year: 2026, month: 7)
        #expect(stats.expenseTotalMinorUnits == 82_000)
        let foodStat = stats.expenseRanking.first { $0.category.uuid == food.uuid }!
        #expect(foodStat.totalMinorUnits == 82_000) // 排行同口径，无双重折算
    }

    @Test func 历史口径永固后记新汇率不改旧月统计() throws {
        let env = try makeEnv()
        let food = try makeCategory(env, name: "餐饮")
        let july = try record(env, kind: .expense, amount: "100", categoryUUID: food.uuid, day: 5)
        try markForeign(july, rate: "7.2")

        let before = try MonthlyStatsProvider(context: env.context)
            .stats(ledgerID: env.ledgerID, year: 2026, month: 7)
        #expect(before.expenseTotalMinorUnits == 72_000)

        // 8 月记入新汇率流水（全库最近快照变为 7.5），7 月统计仍按自身快照 7.2
        let august = try record(env, kind: .expense, amount: "100", categoryUUID: food.uuid, day: 1, month: 8)
        try markForeign(august, rate: "7.5")
        let after = try MonthlyStatsProvider(context: env.context)
            .stats(ledgerID: env.ledgerID, year: 2026, month: 7)
        #expect(after.expenseTotalMinorUnits == 72_000)
    }

    @Test func 外币退款冲减按原单快照折算() throws {
        let env = try makeEnv()
        let food = try makeCategory(env, name: "餐饮")
        let original = try record(env, kind: .expense, amount: "100", categoryUUID: food.uuid, day: 5)
        try markForeign(original, rate: "7.2") // USD 10_000 分 → 72_000 分

        // 退款到账单 + 分摊行直接构造（分摊额以原单币种计，5.5）
        let settlement = Transaction(
            kind: .income, amountMinorUnits: 5_000,
            occurredAt: Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 10))!,
            ledgerID: env.ledgerID
        )
        settlement.settlementKindRawValue = TransactionLinkKind.refund.rawValue
        settlement.currencyCode = "USD"
        settlement.fxRateToBase = Decimal(string: "7.2")!
        env.context.insert(settlement)
        env.context.insert(TransactionLink(
            originalTransactionID: original.uuid,
            settlementTransactionID: settlement.uuid,
            kind: .refund,
            amountMinorUnits: 5_000
        ))
        try env.context.save()

        let stats = try MonthlyStatsProvider(context: env.context)
            .stats(ledgerID: env.ledgerID, year: 2026, month: 7)
        #expect(stats.expenseTotalMinorUnits == 36_000) // 72_000 − 5_000×7.2
        #expect(stats.incomeTotalMinorUnits == 0) // 退款到账不计收入
        let foodStat = stats.expenseRanking.first { $0.category.uuid == food.uuid }!
        #expect(foodStat.totalMinorUnits == 36_000) // 分类冲减与总额同口径
    }

    @Test func 外币转账手续费折算计入fee口径() throws {
        let env = try makeEnv()
        var targetDraft = AccountDraft()
        targetDraft.name = "美元卡"
        let target = try AccountService(context: env.context).createAccount(targetDraft)
        var draft = TransactionDraft()
        draft.kind = .transfer
        draft.amountString = "1000"
        draft.feeString = "5"
        draft.accountUUID = env.accountUUID
        draft.targetAccountUUID = target.uuid
        draft.occurredAt = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 8))!
        let transfer = try TransactionService(context: env.context).recordTransaction(draft, ledgerID: env.ledgerID)
        try markForeign(transfer, rate: "7.2")

        let stats = try MonthlyStatsProvider(context: env.context)
            .stats(ledgerID: env.ledgerID, year: 2026, month: 7)
        #expect(stats.expenseTotalMinorUnits == 3_600) // 500 × 7.2
        #expect(stats.feeTotalMinorUnits == 3_600)
    }

    @Test func 收入排行独立于支出() throws {
        let env = try makeEnv()
        let salary = try makeCategory(env, name: "工资", kind: .income)
        let food = try makeCategory(env, name: "餐饮")
        try record(env, kind: .income, amount: "5000", categoryUUID: salary.uuid, day: 1)
        try record(env, kind: .expense, amount: "100", categoryUUID: food.uuid, day: 2)

        let stats = try MonthlyStatsProvider(context: env.context)
            .stats(ledgerID: env.ledgerID, year: 2026, month: 7)
        #expect(stats.incomeRanking.map(\.category.name) == ["工资"])
        #expect(stats.expenseRanking.map(\.category.name) == ["餐饮"])
    }
}
