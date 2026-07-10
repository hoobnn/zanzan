import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct LedgerCommandsTests {
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
        let commands = LedgerCommands(context: context)
        let first = try commands.createLedger(LedgerDraft(name: "日常"))
        let second = try commands.createLedger(LedgerDraft(name: "旅行"))
        #expect(first.isDefault)
        #expect(!second.isDefault)
        #expect(second.sortOrder == 1)
    }

    @Test func 设默认清除旧默认() throws {
        let context = try makeContext()
        let commands = LedgerCommands(context: context)
        let first = try commands.createLedger(LedgerDraft(name: "日常"))
        let second = try commands.createLedger(LedgerDraft(name: "旅行"))
        try commands.setDefaultLedger(uuid: second.uuid)
        #expect(!first.isDefault)
        #expect(second.isDefault)
    }

    @Test func 默认账本禁删() throws {
        let context = try makeContext()
        let commands = LedgerCommands(context: context)
        let ledger = try commands.createLedger(LedgerDraft(name: "日常"))
        #expect(throws: LedgerCommandError.self) {
            try commands.softDeleteLedger(uuid: ledger.uuid)
        }
    }

    @Test func 有活跃流水阻断删除() throws {
        let context = try makeContext()
        let commands = LedgerCommands(context: context)
        _ = try commands.createLedger(LedgerDraft(name: "日常"))
        let target = try commands.createLedger(LedgerDraft(name: "旅行"))
        let tx = StoredTransaction(kind: .expense, amountMinorUnits: 100, occurredAt: .now, ledgerID: target.uuid)
        context.insert(tx)
        try context.save()
        #expect(throws: LedgerCommandError.self) {
            try commands.softDeleteLedger(uuid: target.uuid)
        }
    }

    @Test func 删除级联软删预算() throws {
        let context = try makeContext()
        let commands = LedgerCommands(context: context)
        _ = try commands.createLedger(LedgerDraft(name: "日常"))
        let target = try commands.createLedger(LedgerDraft(name: "旅行"))
        let budget = StoredBudget(ledgerID: target.uuid, amountMinorUnits: 100_000)
        context.insert(budget)
        try context.save()
        try commands.softDeleteLedger(uuid: target.uuid)
        #expect(target.isSoftDeleted)
        #expect(budget.isSoftDeleted)
    }

    @Test func 改名更新updatedAt() throws {
        let context = try makeContext()
        let commands = LedgerCommands(context: context)
        let ledger = try commands.createLedger(LedgerDraft(name: "日常"))
        let before = ledger.updatedAt
        try commands.updateLedger(uuid: ledger.uuid, draft: LedgerDraft(name: "生活"))
        #expect(ledger.name == "生活")
        #expect(ledger.updatedAt >= before)
    }
}
