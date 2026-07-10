import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct BudgetProgressProviderTests {
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
    private func makeBudget(
        _ env: Env, categoryID: UUID? = nil, year: Int? = nil, month: Int? = nil, amount: Int
    ) throws -> Budget {
        var draft = BudgetDraft(ledgerID: env.ledgerID)
        draft.categoryID = categoryID
        draft.periodYear = year
        draft.periodMonth = month
        draft.amountMinorUnits = amount
        return try BudgetService(context: env.context).createBudget(draft)
    }

    @discardableResult
    private func record(
        _ env: Env, kind: TransactionKind = .expense, amount: String, categoryUUID: UUID?, day: Int, month: Int = 7
    ) throws -> Transaction {
        var draft = TransactionDraft()
        draft.kind = kind
        draft.amountString = amount
        draft.accountUUID = env.accountUUID
        draft.categoryUUID = categoryUUID
        draft.occurredAt = Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day))!
        return try TransactionService(context: env.context).recordTransaction(draft, ledgerID: env.ledgerID)
    }

    private func progress(_ env: Env) throws -> MonthlyBudgetProgress {
        try BudgetProgressProvider(context: env.context)
            .progress(ledgerID: env.ledgerID, year: 2026, month: 7)
    }

    @Test func 总预算已用等于当月支出合计() throws {
        let env = try makeEnv()
        let food = try makeCategory(env, name: "餐饮")
        try makeBudget(env, amount: 100_000)
        try record(env, amount: "100", categoryUUID: food.uuid, day: 5)
        try record(env, amount: "50", categoryUUID: food.uuid, day: 10)
        try record(env, amount: "999", categoryUUID: food.uuid, day: 5, month: 6) // 上月不计

        let result = try progress(env)
        let total = result.total!
        #expect(total.usedMinorUnits == 15_000)
        #expect(total.remainingMinorUnits == 85_000)
        #expect(total.usedFraction == 0.15)
        #expect(result.categories.isEmpty)
    }

    @Test func 分类预算已用含子类rollup() throws {
        let env = try makeEnv()
        let dining = try makeCategory(env, name: "餐饮")
        let breakfast = try makeCategory(env, name: "早餐", parentID: dining.uuid)
        let transport = try makeCategory(env, name: "交通")
        try makeBudget(env, categoryID: dining.uuid, amount: 50_000)
        try record(env, amount: "10", categoryUUID: dining.uuid, day: 1) // 父直挂
        try record(env, amount: "20", categoryUUID: breakfast.uuid, day: 2) // 子类汇入
        try record(env, amount: "99", categoryUUID: transport.uuid, day: 3) // 别的分类不计

        let result = try progress(env)
        #expect(result.categories.count == 1)
        #expect(result.categories.first!.usedMinorUnits == 3_000)
    }

    @Test func 不计预算流水被剔除() throws {
        let env = try makeEnv()
        let food = try makeCategory(env, name: "餐饮")
        try makeBudget(env, amount: 100_000)
        try makeBudget(env, categoryID: food.uuid, amount: 50_000)
        try record(env, amount: "30", categoryUUID: food.uuid, day: 1)
        let excluded = try record(env, amount: "70", categoryUUID: food.uuid, day: 2)
        excluded.isExcludedFromBudget = true
        try env.context.save()

        let result = try progress(env)
        #expect(result.total!.usedMinorUnits == 3_000)
        #expect(result.categories.first!.usedMinorUnits == 3_000)
    }

    @Test func 软删流水被剔除() throws {
        let env = try makeEnv()
        let food = try makeCategory(env, name: "餐饮")
        try makeBudget(env, amount: 100_000)
        let deleted = try record(env, amount: "40", categoryUUID: food.uuid, day: 1)
        deleted.isSoftDeleted = true
        try env.context.save()

        #expect(try progress(env).total!.usedMinorUnits == 0)
    }

    @Test func 已报销支出被剔除() throws {
        let env = try makeEnv()
        let food = try makeCategory(env, name: "餐饮")
        try makeBudget(env, amount: 100_000)
        let waiting = try record(env, amount: "30", categoryUUID: food.uuid, day: 1)
        waiting.reimbursementStatusRawValue = ReimbursementStatus.waiting.rawValue
        let settled = try record(env, amount: "70", categoryUUID: food.uuid, day: 2)
        settled.reimbursementStatusRawValue = ReimbursementStatus.settled.rawValue
        try env.context.save()

        // 待报销仍计入已用（钱确实花出去了），已报销剔除（设计文档 5.7）
        #expect(try progress(env).total!.usedMinorUnits == 3_000)
    }

    @Test func 月度实体行优先于模板行() throws {
        let env = try makeEnv()
        try makeBudget(env, amount: 100_000) // 模板
        try makeBudget(env, year: 2026, month: 7, amount: 88_000) // 当月实体行

        let result = try progress(env)
        #expect(result.total!.budget.amountMinorUnits == 88_000)
        #expect(result.total!.budget.periodYear == 2026)
    }

    @Test func 无实体行回落模板行() throws {
        let env = try makeEnv()
        try makeBudget(env, amount: 100_000)
        try makeBudget(env, year: 2026, month: 8, amount: 88_000) // 别的月份不生效

        let result = try progress(env)
        #expect(result.total!.budget.amountMinorUnits == 100_000)
        #expect(result.total!.budget.periodYear == nil)
    }

    @Test func 软删预算行不出现在进度里() throws {
        let env = try makeEnv()
        let service = BudgetService(context: env.context)
        let budget = try makeBudget(env, amount: 100_000)
        try service.softDeleteBudget(uuid: budget.uuid)

        let result = try progress(env)
        #expect(result.total == nil)
        #expect(result.categories.isEmpty)
    }

    @Test func 无预算返回空全景() throws {
        let env = try makeEnv()
        let result = try progress(env)
        #expect(result.total == nil)
        #expect(result.categories.isEmpty)
    }

    @Test func 分类预算按已用额降序() throws {
        let env = try makeEnv()
        let dining = try makeCategory(env, name: "餐饮")
        let transport = try makeCategory(env, name: "交通")
        try makeBudget(env, categoryID: dining.uuid, amount: 50_000)
        try makeBudget(env, categoryID: transport.uuid, amount: 50_000)
        try record(env, amount: "10", categoryUUID: dining.uuid, day: 1)
        try record(env, amount: "50", categoryUUID: transport.uuid, day: 2)

        let result = try progress(env)
        #expect(result.categories.map(\.usedMinorUnits) == [5_000, 1_000])
    }

    @Test func 无效月份被拒() throws {
        let env = try makeEnv()
        #expect(throws: BudgetProgressError.self) {
            try BudgetProgressProvider(context: env.context)
                .progress(ledgerID: env.ledgerID, year: 2026, month: 0)
        }
    }
}
