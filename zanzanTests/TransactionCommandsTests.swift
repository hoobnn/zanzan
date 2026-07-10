import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct TransactionCommandsTests {
    /// 建好账本/账户/分类的公共夹具
    private struct Fixture {
        let context: ModelContext
        let ledger: StoredLedger
        let cash: StoredAccount
        let card: StoredAccount
        let dining: StoredCategory   // expense
        let salary: StoredCategory   // income
    }

    private func makeFixture() throws -> Fixture {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let ledger = try LedgerCommands(context: context).createLedger(LedgerDraft(name: "日常"))
        let cash = StoredAccount(name: "现金", kind: .fund)
        let card = StoredAccount(name: "储蓄卡", kind: .fund)
        let dining = StoredCategory(name: "餐饮", kind: .expense, sortOrder: 0)
        let salary = StoredCategory(name: "工资", kind: .income, sortOrder: 0)
        context.insert(cash)
        context.insert(card)
        context.insert(dining)
        context.insert(salary)
        try context.save()
        return Fixture(context: context, ledger: ledger, cash: cash, card: card, dining: dining, salary: salary)
    }

    private func expenseDraft(_ f: Fixture, amount: String = "25.50") -> TransactionDraft {
        var draft = TransactionDraft()
        draft.kind = .expense
        draft.amountString = amount
        draft.accountUUID = f.cash.uuid
        draft.categoryUUID = f.dining.uuid
        return draft
    }

    @Test func 记支出流水落库() throws {
        let f = try makeFixture()
        let tx = try TransactionCommands(context: f.context).recordTransaction(expenseDraft(f), ledgerID: f.ledger.uuid)
        #expect(tx.kind == .expense)
        #expect(tx.amountMinorUnits == 2_550)
        #expect(tx.ledgerID == f.ledger.uuid)
        #expect(tx.account?.uuid == f.cash.uuid)
        #expect(tx.category?.uuid == f.dining.uuid)
        #expect(tx.feeMinorUnits == 0)          // 非转账 fee 恒 0（不变量）
        #expect(tx.currencyCode == "CNY")
        #expect(tx.fxRateToBase == nil)          // 本位币流水恒 nil
        #expect(tx.sourceKind == .manual)
    }

    @Test func 非转账草稿手续费被归零() throws {
        let f = try makeFixture()
        var draft = expenseDraft(f)
        draft.feeString = "5" // 表单不该出现，防御性归一化
        let tx = try TransactionCommands(context: f.context).recordTransaction(draft, ledgerID: f.ledger.uuid)
        #expect(tx.feeMinorUnits == 0)
    }

    @Test func ledgerID必须指向活跃账本() throws {
        let f = try makeFixture()
        #expect(throws: TransactionCommandError.self) {
            _ = try TransactionCommands(context: f.context).recordTransaction(self.expenseDraft(f), ledgerID: UUID())
        }
    }

    @Test func 分类方向不匹配阻断() throws {
        let f = try makeFixture()
        var draft = expenseDraft(f)
        draft.categoryUUID = f.salary.uuid // 支出挂收入分类
        #expect(throws: TransactionCommandError.self) {
            _ = try TransactionCommands(context: f.context).recordTransaction(draft, ledgerID: f.ledger.uuid)
        }
    }

    @Test func 金额非法被拒() throws {
        let f = try makeFixture()
        var draft = expenseDraft(f, amount: "0")
        #expect(throws: TransactionDraftError.self) { _ = try draft.validated() }
        draft.amountString = "abc"
        #expect(throws: TransactionDraftError.self) { _ = try draft.validated() }
    }

    @Test func 转账禁自转且必有双方() throws {
        let f = try makeFixture()
        var draft = TransactionDraft()
        draft.kind = .transfer
        draft.amountString = "100"
        draft.accountUUID = f.cash.uuid
        draft.targetAccountUUID = f.cash.uuid
        #expect(throws: TransactionDraftError.self) { _ = try draft.validated() } // 自转
        draft.targetAccountUUID = nil
        #expect(throws: TransactionDraftError.self) { _ = try draft.validated() } // 缺转入方
    }

    @Test func 转账手续费落库() throws {
        let f = try makeFixture()
        var draft = TransactionDraft()
        draft.kind = .transfer
        draft.amountString = "100"
        draft.feeString = "0.50"
        draft.accountUUID = f.cash.uuid
        draft.targetAccountUUID = f.card.uuid
        let tx = try TransactionCommands(context: f.context).recordTransaction(draft, ledgerID: f.ledger.uuid)
        #expect(tx.feeMinorUnits == 50)
        #expect(tx.targetAccount?.uuid == f.card.uuid)
        #expect(tx.category == nil) // 转账不挂分类
    }

    @Test func kind终生不可改写() throws {
        let f = try makeFixture()
        let tx = try TransactionCommands(context: f.context).recordTransaction(expenseDraft(f), ledgerID: f.ledger.uuid)
        var draft = expenseDraft(f)
        draft.kind = .income
        draft.categoryUUID = f.salary.uuid
        #expect(throws: TransactionCommandError.self) {
            try TransactionCommands(context: f.context).updateTransaction(uuid: tx.uuid, draft: draft)
        }
    }

    @Test func 编辑更新字段与updatedAt() throws {
        let f = try makeFixture()
        let commands = TransactionCommands(context: f.context)
        let tx = try commands.recordTransaction(expenseDraft(f), ledgerID: f.ledger.uuid)
        var draft = expenseDraft(f, amount: "30")
        draft.note = "改备注"
        draft.accountUUID = f.card.uuid
        try commands.updateTransaction(uuid: tx.uuid, draft: draft)
        #expect(tx.amountMinorUnits == 3_000)
        #expect(tx.note == "改备注")
        #expect(tx.account?.uuid == f.card.uuid)
    }

    @Test func 软删与撤销() throws {
        let f = try makeFixture()
        let commands = TransactionCommands(context: f.context)
        let tx = try commands.recordTransaction(expenseDraft(f), ledgerID: f.ledger.uuid)
        try commands.softDeleteTransaction(uuid: tx.uuid)
        #expect(tx.isSoftDeleted)
        try commands.undoSoftDeleteTransaction(uuid: tx.uuid)
        #expect(!tx.isSoftDeleted)
    }
}
