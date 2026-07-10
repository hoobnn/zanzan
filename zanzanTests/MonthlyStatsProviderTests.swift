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
