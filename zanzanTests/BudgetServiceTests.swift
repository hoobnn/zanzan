import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct BudgetServiceTests {
    private struct Env {
        let context: ModelContext
        let ledgerID: UUID
    }

    private func makeEnv() throws -> Env {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let ledger = try LedgerService(context: context).createLedger(LedgerDraft(name: "测试账本"))
        return Env(context: context, ledgerID: ledger.uuid)
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

    private func makeDraft(
        _ env: Env, categoryID: UUID? = nil, year: Int? = nil, month: Int? = nil, amount: Int = 100_000
    ) -> BudgetDraft {
        var draft = BudgetDraft(ledgerID: env.ledgerID)
        draft.categoryID = categoryID
        draft.periodYear = year
        draft.periodMonth = month
        draft.amountMinorUnits = amount
        return draft
    }

    private func budgetCount(_ env: Env) throws -> Int {
        try env.context.fetchCount(FetchDescriptor<Budget>())
    }

    // MARK: - 创建

    @Test func 创建总预算模板行() throws {
        let env = try makeEnv()
        let budget = try BudgetService(context: env.context).createBudget(makeDraft(env))
        #expect(budget.ledgerID == env.ledgerID)
        #expect(budget.categoryID == nil)
        #expect(budget.periodYear == nil)
        #expect(budget.periodMonth == nil)
        #expect(budget.amountMinorUnits == 100_000)
        #expect(!budget.isSoftDeleted)
    }

    @Test func 创建分类预算模板行() throws {
        let env = try makeEnv()
        let dining = try makeCategory(env, name: "餐饮")
        let budget = try BudgetService(context: env.context)
            .createBudget(makeDraft(env, categoryID: dining.uuid, amount: 50_000))
        #expect(budget.categoryID == dining.uuid)
    }

    @Test func 同维度重复创建被拒() throws {
        let env = try makeEnv()
        let service = BudgetService(context: env.context)
        try service.createBudget(makeDraft(env))
        #expect(throws: BudgetServiceError.self) {
            try service.createBudget(makeDraft(env, amount: 200_000))
        }
    }

    @Test func 收入分类预算被拒() throws {
        let env = try makeEnv()
        let salary = try makeCategory(env, name: "工资", kind: .income)
        #expect(throws: BudgetServiceError.self) {
            try BudgetService(context: env.context).createBudget(makeDraft(env, categoryID: salary.uuid))
        }
    }

    @Test func 子分类预算被拒() throws {
        let env = try makeEnv()
        let dining = try makeCategory(env, name: "餐饮")
        let breakfast = try makeCategory(env, name: "早餐", parentID: dining.uuid)
        #expect(throws: BudgetServiceError.self) {
            try BudgetService(context: env.context).createBudget(makeDraft(env, categoryID: breakfast.uuid))
        }
    }

    @Test func 软删分类预算被拒() throws {
        let env = try makeEnv()
        let dining = try makeCategory(env, name: "餐饮")
        try CategoryService(context: env.context).softDeleteCategory(uuid: dining.uuid)
        #expect(throws: BudgetServiceError.self) {
            try BudgetService(context: env.context).createBudget(makeDraft(env, categoryID: dining.uuid))
        }
    }

    @Test func 金额非正经草稿被拒() throws {
        let env = try makeEnv()
        #expect(throws: BudgetDraftError.self) {
            try BudgetService(context: env.context).createBudget(makeDraft(env, amount: 0))
        }
    }

    // MARK: - 更新 / 软删

    @Test func 更新额度() throws {
        let env = try makeEnv()
        let service = BudgetService(context: env.context)
        let budget = try service.createBudget(makeDraft(env))
        try service.updateAmount(uuid: budget.uuid, amountMinorUnits: 300_000)
        #expect(budget.amountMinorUnits == 300_000)
    }

    @Test func 更新额度非正被拒() throws {
        let env = try makeEnv()
        let service = BudgetService(context: env.context)
        let budget = try service.createBudget(makeDraft(env))
        #expect(throws: BudgetDraftError.self) {
            try service.updateAmount(uuid: budget.uuid, amountMinorUnits: -1)
        }
    }

    @Test func 软删后不可再更新() throws {
        let env = try makeEnv()
        let service = BudgetService(context: env.context)
        let budget = try service.createBudget(makeDraft(env))
        try service.softDeleteBudget(uuid: budget.uuid)
        #expect(budget.isSoftDeleted)
        #expect(throws: BudgetServiceError.self) {
            try service.updateAmount(uuid: budget.uuid, amountMinorUnits: 100)
        }
    }

    @Test func 软删后同维度可重建() throws {
        let env = try makeEnv()
        let service = BudgetService(context: env.context)
        let budget = try service.createBudget(makeDraft(env))
        try service.softDeleteBudget(uuid: budget.uuid)
        let rebuilt = try service.createBudget(makeDraft(env, amount: 200_000))
        #expect(rebuilt.amountMinorUnits == 200_000)
    }

    // MARK: - materialize

    @Test func 物化生成当月实体行() throws {
        let env = try makeEnv()
        let dining = try makeCategory(env, name: "餐饮")
        let service = BudgetService(context: env.context)
        try service.createBudget(makeDraft(env, amount: 100_000)) // 总预算模板
        try service.createBudget(makeDraft(env, categoryID: dining.uuid, amount: 50_000))

        let created = try service.materialize(ledgerID: env.ledgerID, year: 2026, month: 7)

        #expect(created.count == 2)
        #expect(created.allSatisfy { $0.periodYear == 2026 && $0.periodMonth == 7 })
        let monthlyTotal = created.first { $0.categoryID == nil }!
        #expect(monthlyTotal.amountMinorUnits == 100_000)
        #expect(try budgetCount(env) == 4) // 2 模板 + 2 月度
    }

    @Test func 物化幂等重复调用不重复生成() throws {
        let env = try makeEnv()
        let service = BudgetService(context: env.context)
        try service.createBudget(makeDraft(env))
        let first = try service.materialize(ledgerID: env.ledgerID, year: 2026, month: 7)
        let second = try service.materialize(ledgerID: env.ledgerID, year: 2026, month: 7)
        #expect(first.count == 1)
        #expect(second.isEmpty)
        #expect(try budgetCount(env) == 2) // 1 模板 + 1 月度
    }

    @Test func 物化不覆盖已改额的月度行() throws {
        let env = try makeEnv()
        let service = BudgetService(context: env.context)
        try service.createBudget(makeDraft(env, amount: 100_000))
        let monthly = try service.materialize(ledgerID: env.ledgerID, year: 2026, month: 7).first!
        try service.updateAmount(uuid: monthly.uuid, amountMinorUnits: 66_600)

        let again = try service.materialize(ledgerID: env.ledgerID, year: 2026, month: 7)

        #expect(again.isEmpty)
        #expect(monthly.amountMinorUnits == 66_600)
    }

    @Test func 软删模板不参与物化() throws {
        let env = try makeEnv()
        let service = BudgetService(context: env.context)
        let template = try service.createBudget(makeDraft(env))
        try service.softDeleteBudget(uuid: template.uuid)
        let created = try service.materialize(ledgerID: env.ledgerID, year: 2026, month: 7)
        #expect(created.isEmpty)
    }

    @Test func 物化无效月份被拒() throws {
        let env = try makeEnv()
        #expect(throws: BudgetServiceError.self) {
            try BudgetService(context: env.context).materialize(ledgerID: env.ledgerID, year: 2026, month: 13)
        }
    }
}
