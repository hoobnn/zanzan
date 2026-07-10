import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct TransactionListProjectionTests {
    private struct Env {
        let context: ModelContext
        let ledgerID: UUID
        let accountUUID: UUID
        let categoryUUID: UUID
    }

    private func makeEnv() throws -> Env {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let ledger = try LedgerCommands(context: context).createLedger(LedgerDraft(name: "测试账本"))
        var accountDraft = AccountDraft()
        accountDraft.name = "现金"
        let account = try AccountCommands(context: context).createAccount(accountDraft)
        var categoryDraft = CategoryDraft()
        categoryDraft.name = "餐饮"
        let category = try CategoryCommands(context: context).createCategory(categoryDraft)
        return Env(context: context, ledgerID: ledger.uuid, accountUUID: account.uuid, categoryUUID: category.uuid)
    }

    @discardableResult
    private func record(
        _ env: Env, kind: TransactionKind = .expense, amount: String = "10", day: Int, month: Int = 7
    ) throws -> StoredTransaction {
        var draft = TransactionDraft()
        draft.kind = kind
        draft.amountString = amount
        draft.accountUUID = env.accountUUID
        draft.categoryUUID = env.categoryUUID
        draft.occurredAt = Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
        return try TransactionCommands(context: env.context).recordTransaction(draft, ledgerID: env.ledgerID)
    }

    @Test func 按类型筛选() throws {
        let env = try makeEnv()
        var incomeCategoryDraft = CategoryDraft()
        incomeCategoryDraft.name = "工资"
        incomeCategoryDraft.kind = .income
        let incomeCategory = try CategoryCommands(context: env.context).createCategory(incomeCategoryDraft)
        try record(env, day: 1)
        var incomeDraft = TransactionDraft()
        incomeDraft.kind = .income
        incomeDraft.amountString = "5000"
        incomeDraft.accountUUID = env.accountUUID
        incomeDraft.categoryUUID = incomeCategory.uuid
        try TransactionCommands(context: env.context).recordTransaction(incomeDraft, ledgerID: env.ledgerID)

        var filter = TransactionListFilter(ledgerID: env.ledgerID)
        filter.kind = .expense
        let results = try env.context.fetch(filter.fetchDescriptor())
        #expect(results.count == 1)
        #expect(results[0].kind == .expense)
    }

    @Test func 按账户筛选命中转账双方() throws {
        let env = try makeEnv()
        var otherDraft = AccountDraft()
        otherDraft.name = "储蓄卡"
        let other = try AccountCommands(context: env.context).createAccount(otherDraft)
        try record(env, day: 1) // 现金支出
        var transfer = TransactionDraft()
        transfer.kind = .transfer
        transfer.amountString = "100"
        transfer.accountUUID = env.accountUUID
        transfer.targetAccountUUID = other.uuid
        try TransactionCommands(context: env.context).recordTransaction(transfer, ledgerID: env.ledgerID)

        var filter = TransactionListFilter(ledgerID: env.ledgerID)
        filter.accountUUID = other.uuid
        let results = try env.context.fetch(filter.fetchDescriptor())
        #expect(results.count == 1)
        #expect(results[0].kind == .transfer)
    }

    @Test func 无筛选返回账本全量降序() throws {
        let env = try makeEnv()
        try record(env, day: 1)
        try record(env, day: 15)
        let filter = TransactionListFilter(ledgerID: env.ledgerID)
        let results = try env.context.fetch(filter.fetchDescriptor())
        #expect(results.count == 2)
        #expect(results[0].occurredAt > results[1].occurredAt)
    }

    @Test func 日月分组含小计() throws {
        let env = try makeEnv()
        try record(env, amount: "10", day: 1)
        try record(env, amount: "20", day: 1)
        try record(env, amount: "30", day: 15)
        try record(env, amount: "40", day: 1, month: 6)

        let filter = TransactionListFilter(ledgerID: env.ledgerID)
        let results = try env.context.fetch(filter.fetchDescriptor())
        let months = TransactionListGrouping.monthGroups(of: results)

        #expect(months.count == 2)
        #expect(months[0].expenseTotalMinorUnits == 6_000) // 7 月
        #expect(months[0].days.count == 2)
        #expect(months[0].days[0].expenseTotalMinorUnits == 3_000) // 15 日在前（降序）
        #expect(months[0].days[1].expenseTotalMinorUnits == 3_000) // 1 日两笔
        #expect(months[1].expenseTotalMinorUnits == 4_000) // 6 月
    }

    @Test func 不计统计流水显示但不进小计() throws {
        let env = try makeEnv()
        try record(env, amount: "10", day: 1)
        let excluded = try record(env, amount: "99", day: 1)
        excluded.isExcludedFromStats = true
        try env.context.save()

        let filter = TransactionListFilter(ledgerID: env.ledgerID)
        let results = try env.context.fetch(filter.fetchDescriptor())
        let months = TransactionListGrouping.monthGroups(of: results)
        #expect(months[0].days[0].items.count == 2)
        #expect(months[0].days[0].expenseTotalMinorUnits == 1_000)
    }
}
