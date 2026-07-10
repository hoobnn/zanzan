import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct LedgerServiceTests {
    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    @Test func 空名草稿被拒() throws {
        #expect(throws: LedgerDraftError.self) {
            _ = try LedgerDraft(name: "  ").validated()
        }
    }

    @Test func 首本自动成为默认账本() throws {
        let context = try makeContext()
        let commands = LedgerService(context: context)
        let first = try commands.createLedger(LedgerDraft(name: "日常"))
        let second = try commands.createLedger(LedgerDraft(name: "旅行"))
        #expect(first.isDefault)
        #expect(!second.isDefault)
        #expect(second.sortOrder == 1)
    }

    @Test func 设默认清除旧默认() throws {
        let context = try makeContext()
        let commands = LedgerService(context: context)
        let first = try commands.createLedger(LedgerDraft(name: "日常"))
        let second = try commands.createLedger(LedgerDraft(name: "旅行"))
        try commands.setDefaultLedger(uuid: second.uuid)
        #expect(!first.isDefault)
        #expect(second.isDefault)
    }

    @Test func 默认账本禁删() throws {
        let context = try makeContext()
        let commands = LedgerService(context: context)
        let ledger = try commands.createLedger(LedgerDraft(name: "日常"))
        #expect(throws: LedgerServiceError.self) {
            try commands.softDeleteLedger(uuid: ledger.uuid)
        }
    }

    @Test func 有活跃流水阻断删除() throws {
        let context = try makeContext()
        let commands = LedgerService(context: context)
        _ = try commands.createLedger(LedgerDraft(name: "日常"))
        let target = try commands.createLedger(LedgerDraft(name: "旅行"))
        let tx = Transaction(kind: .expense, amountMinorUnits: 100, occurredAt: .now, ledgerID: target.uuid)
        context.insert(tx)
        try context.save()
        #expect(throws: LedgerServiceError.self) {
            try commands.softDeleteLedger(uuid: target.uuid)
        }
    }

    @Test func 删除级联软删预算() throws {
        let context = try makeContext()
        let commands = LedgerService(context: context)
        _ = try commands.createLedger(LedgerDraft(name: "日常"))
        let target = try commands.createLedger(LedgerDraft(name: "旅行"))
        let budget = Budget(ledgerID: target.uuid, amountMinorUnits: 100_000)
        context.insert(budget)
        try context.save()
        try commands.softDeleteLedger(uuid: target.uuid)
        #expect(target.isSoftDeleted)
        #expect(budget.isSoftDeleted)
    }

    @Test func 有活跃周期规则引用阻断删除() throws {
        let context = try makeContext()
        let commands = LedgerService(context: context)
        _ = try commands.createLedger(LedgerDraft(name: "日常"))
        let target = try commands.createLedger(LedgerDraft(name: "旅行"))
        let rule = RecurringRule(
            name: "房租", frequency: .monthly, startAt: .now, nextRunAt: .now,
            templateKind: .expense, templateAmountMinorUnits: 100
        )
        rule.templateLedgerID = target.uuid
        context.insert(rule)
        try context.save()
        #expect(throws: LedgerServiceError.self) {
            try commands.softDeleteLedger(uuid: target.uuid)
        }
    }

    @Test func 有活跃分期计划引用阻断删除() throws {
        let context = try makeContext()
        let commands = LedgerService(context: context)
        _ = try commands.createLedger(LedgerDraft(name: "日常"))
        let target = try commands.createLedger(LedgerDraft(name: "旅行"))
        let plan = InstallmentPlan(
            name: "手机分期", kind: .purchase, accountID: UUID(), ledgerID: target.uuid,
            principalMinorUnits: 120_000, totalPeriods: 12, amortizationKind: .flatFee, firstDueAt: .now
        )
        context.insert(plan)
        try context.save()
        #expect(throws: LedgerServiceError.self) {
            try commands.softDeleteLedger(uuid: target.uuid)
        }
    }

    @Test func 撤销软删恢复账本并级联恢复预算() throws {
        let context = try makeContext()
        let commands = LedgerService(context: context)
        _ = try commands.createLedger(LedgerDraft(name: "日常"))
        let target = try commands.createLedger(LedgerDraft(name: "旅行"))
        let budget = Budget(ledgerID: target.uuid, amountMinorUnits: 100_000)
        context.insert(budget)
        try context.save()
        try commands.softDeleteLedger(uuid: target.uuid)
        try commands.undoSoftDeleteLedger(uuid: target.uuid)
        #expect(!target.isSoftDeleted)
        #expect(!budget.isSoftDeleted)
        #expect(!target.isDefault) // 不回抢默认位
    }

    @Test func 撤销恢复不复活分类已删的预算行() throws {
        let context = try makeContext()
        let commands = LedgerService(context: context)
        _ = try commands.createLedger(LedgerDraft(name: "日常"))
        let target = try commands.createLedger(LedgerDraft(name: "旅行"))
        let category = Category(name: "餐饮", kind: .expense, sortOrder: 0)
        category.isSoftDeleted = true
        context.insert(category)
        let budget = Budget(ledgerID: target.uuid, amountMinorUnits: 100_000)
        budget.categoryID = category.uuid
        context.insert(budget)
        try context.save()
        try commands.softDeleteLedger(uuid: target.uuid)
        try commands.undoSoftDeleteLedger(uuid: target.uuid)
        #expect(!target.isSoftDeleted)
        #expect(budget.isSoftDeleted) // 分类不活跃，守卫跳过
    }

    @Test func 双重恢复幂等() throws {
        let context = try makeContext()
        let commands = LedgerService(context: context)
        _ = try commands.createLedger(LedgerDraft(name: "日常"))
        let target = try commands.createLedger(LedgerDraft(name: "旅行"))
        try commands.softDeleteLedger(uuid: target.uuid)
        try commands.undoSoftDeleteLedger(uuid: target.uuid)
        try commands.undoSoftDeleteLedger(uuid: target.uuid)
        #expect(!target.isSoftDeleted)
    }

    @Test func 改名更新updatedAt() throws {
        let context = try makeContext()
        let commands = LedgerService(context: context)
        let ledger = try commands.createLedger(LedgerDraft(name: "日常"))
        let before = ledger.updatedAt
        try commands.updateLedger(uuid: ledger.uuid, draft: LedgerDraft(name: "生活"))
        #expect(ledger.name == "生活")
        #expect(ledger.updatedAt >= before)
    }
}
