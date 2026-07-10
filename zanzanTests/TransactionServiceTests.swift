import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct TransactionServiceTests {
    /// 建好账本/账户/分类的公共夹具
    private struct Fixture {
        let context: ModelContext
        let ledger: Ledger
        let cash: Account
        let card: Account
        let dining: Category   // expense
        let salary: Category   // income
    }

    private func makeFixture() throws -> Fixture {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let ledger = try LedgerService(context: context).createLedger(LedgerDraft(name: "日常"))
        let cash = Account(name: "现金", kind: .fund)
        let card = Account(name: "储蓄卡", kind: .fund)
        let dining = Category(name: "餐饮", kind: .expense, sortOrder: 0)
        let salary = Category(name: "工资", kind: .income, sortOrder: 0)
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
        let tx = try TransactionService(context: f.context).recordTransaction(expenseDraft(f), ledgerID: f.ledger.uuid)
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
        let tx = try TransactionService(context: f.context).recordTransaction(draft, ledgerID: f.ledger.uuid)
        #expect(tx.feeMinorUnits == 0)
    }

    @Test func ledgerID必须指向活跃账本() throws {
        let f = try makeFixture()
        #expect(throws: TransactionServiceError.self) {
            _ = try TransactionService(context: f.context).recordTransaction(self.expenseDraft(f), ledgerID: UUID())
        }
    }

    @Test func 分类方向不匹配阻断() throws {
        let f = try makeFixture()
        var draft = expenseDraft(f)
        draft.categoryUUID = f.salary.uuid // 支出挂收入分类
        #expect(throws: TransactionServiceError.self) {
            _ = try TransactionService(context: f.context).recordTransaction(draft, ledgerID: f.ledger.uuid)
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
        let tx = try TransactionService(context: f.context).recordTransaction(draft, ledgerID: f.ledger.uuid)
        #expect(tx.feeMinorUnits == 50)
        #expect(tx.targetAccount?.uuid == f.card.uuid)
        #expect(tx.category == nil) // 转账不挂分类
    }

    @Test func kind终生不可改写() throws {
        let f = try makeFixture()
        let tx = try TransactionService(context: f.context).recordTransaction(expenseDraft(f), ledgerID: f.ledger.uuid)
        var draft = expenseDraft(f)
        draft.kind = .income
        draft.categoryUUID = f.salary.uuid
        #expect(throws: TransactionServiceError.self) {
            try TransactionService(context: f.context).updateTransaction(uuid: tx.uuid, draft: draft)
        }
    }

    @Test func 编辑更新字段与updatedAt() throws {
        let f = try makeFixture()
        let commands = TransactionService(context: f.context)
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
        let commands = TransactionService(context: f.context)
        let tx = try commands.recordTransaction(expenseDraft(f), ledgerID: f.ledger.uuid)
        try commands.softDeleteTransaction(uuid: tx.uuid)
        #expect(tx.isSoftDeleted)
        try commands.undoSoftDeleteTransaction(uuid: tx.uuid)
        #expect(!tx.isSoftDeleted)
    }

    // MARK: - 多币种（§5.4 必填规则）

    /// 建一个 USD 账户
    private func makeUSDAccount(_ f: Fixture) throws -> Account {
        let usd = Account(name: "美元卡", kind: .fund)
        usd.currencyCode = "USD"
        f.context.insert(usd)
        try f.context.save()
        return usd
    }

    @Test func 外币支出显式汇率落库() throws {
        let f = try makeFixture()
        let usd = try makeUSDAccount(f)
        var draft = expenseDraft(f)
        draft.accountUUID = usd.uuid
        draft.fxRateString = "7.25"
        let tx = try TransactionService(context: f.context).recordTransaction(draft, ledgerID: f.ledger.uuid)
        #expect(tx.currencyCode == "USD")
        #expect(tx.fxRateToBase == Decimal(string: "7.25"))
    }

    @Test func 外币支出无显式汇率用最近快照预填() throws {
        let f = try makeFixture()
        let usd = try makeUSDAccount(f)
        let commands = TransactionService(context: f.context)
        var first = expenseDraft(f)
        first.accountUUID = usd.uuid
        first.fxRateString = "7.10"
        first.occurredAt = .now.addingTimeInterval(-3_600)
        _ = try commands.recordTransaction(first, ledgerID: f.ledger.uuid)
        var second = expenseDraft(f)
        second.accountUUID = usd.uuid // 不填汇率
        let tx = try commands.recordTransaction(second, ledgerID: f.ledger.uuid)
        #expect(tx.fxRateToBase == Decimal(string: "7.10"))
    }

    @Test func 外币支出无汇率无快照抛错() throws {
        let f = try makeFixture()
        let usd = try makeUSDAccount(f)
        var draft = expenseDraft(f)
        draft.accountUUID = usd.uuid
        #expect(throws: TransactionServiceError.self) {
            _ = try TransactionService(context: f.context).recordTransaction(draft, ledgerID: f.ledger.uuid)
        }
    }

    @Test func CNY流水草稿汇率被归nil() throws {
        let f = try makeFixture()
        var draft = expenseDraft(f)
        draft.fxRateString = "7.25" // 本位币流水恒 nil，草稿给了也归 nil
        let tx = try TransactionService(context: f.context).recordTransaction(draft, ledgerID: f.ledger.uuid)
        #expect(tx.currencyCode == "CNY")
        #expect(tx.fxRateToBase == nil)
    }

    @Test func 汇率与到账金额格式非法被拒() throws {
        let f = try makeFixture()
        var draft = expenseDraft(f)
        draft.fxRateString = "-7.2"
        #expect(throws: TransactionDraftError.self) { _ = try draft.validated() }
        var transfer = TransactionDraft()
        transfer.kind = .transfer
        transfer.amountString = "100"
        transfer.accountUUID = f.cash.uuid
        transfer.targetAccountUUID = f.card.uuid
        transfer.targetAmountString = "0"
        #expect(throws: TransactionDraftError.self) { _ = try transfer.validated() }
    }

    @Test func 跨币种转账到账金额必填() throws {
        let f = try makeFixture()
        let usd = try makeUSDAccount(f)
        var draft = TransactionDraft()
        draft.kind = .transfer
        draft.amountString = "725" // CNY → USD，转出方本位币无需汇率
        draft.accountUUID = f.cash.uuid
        draft.targetAccountUUID = usd.uuid
        #expect(throws: TransactionServiceError.self) {
            _ = try TransactionService(context: f.context).recordTransaction(draft, ledgerID: f.ledger.uuid)
        }
    }

    @Test func 跨币种转账余额派生() throws {
        let f = try makeFixture()
        let usd = try makeUSDAccount(f)
        var draft = TransactionDraft()
        draft.kind = .transfer
        draft.amountString = "725"       // 转出 725 CNY
        draft.feeString = "5"            // 手续费 5 CNY
        draft.targetAmountString = "100" // 到账 100 USD
        draft.accountUUID = f.cash.uuid
        draft.targetAccountUUID = usd.uuid
        let tx = try TransactionService(context: f.context).recordTransaction(draft, ledgerID: f.ledger.uuid)
        #expect(tx.currencyCode == "CNY") // 转账记转出方币种
        #expect(tx.fxRateToBase == nil)
        #expect(tx.targetAmountMinorUnits == 10_000)
        #expect(tx.balanceDeltaMinorUnits(for: f.cash.uuid) == -(72_500 + 500)) // 转出 −(amount+fee) 原币
        #expect(tx.balanceDeltaMinorUnits(for: usd.uuid) == 10_000)             // 转入 +targetAmount 目标币
    }

    @Test func 外币转出方转账强制汇率() throws {
        let f = try makeFixture()
        let usd = try makeUSDAccount(f)
        var draft = TransactionDraft()
        draft.kind = .transfer
        draft.amountString = "100" // USD → CNY
        draft.accountUUID = usd.uuid
        draft.targetAccountUUID = f.cash.uuid
        draft.targetAmountString = "725"
        #expect(throws: TransactionServiceError.self) { // 无汇率无快照
            _ = try TransactionService(context: f.context).recordTransaction(draft, ledgerID: f.ledger.uuid)
        }
        draft.fxRateString = "7.25"
        let tx = try TransactionService(context: f.context).recordTransaction(draft, ledgerID: f.ledger.uuid)
        #expect(tx.currencyCode == "USD")
        #expect(tx.fxRateToBase == Decimal(string: "7.25"))
        #expect(tx.targetAmountMinorUnits == 72_500)
    }

    @Test func 同币种转账到账金额归nil() throws {
        let f = try makeFixture()
        var draft = TransactionDraft()
        draft.kind = .transfer
        draft.amountString = "100"
        draft.targetAmountString = "99" // 同币种强制归 nil，草稿给了也归 nil
        draft.accountUUID = f.cash.uuid
        draft.targetAccountUUID = f.card.uuid
        let tx = try TransactionService(context: f.context).recordTransaction(draft, ledgerID: f.ledger.uuid)
        #expect(tx.targetAmountMinorUnits == nil)
        #expect(tx.balanceDeltaMinorUnits(for: f.card.uuid) == 10_000) // 转入按 amount
    }

    @Test func 分期来源流水禁止通用删改恢复() throws {
        let f = try makeFixture()
        let commands = TransactionService(context: f.context)
        let tx = try commands.recordTransaction(expenseDraft(f), ledgerID: f.ledger.uuid)
        // 模拟期供流水：生命周期归 InstallmentService 管，通用入口一律阻断
        tx.sourceKindRawValue = TransactionSourceKind.installment.rawValue
        try f.context.save()
        #expect(throws: TransactionServiceError.self) {
            try commands.updateTransaction(uuid: tx.uuid, draft: expenseDraft(f, amount: "99"))
        }
        #expect(throws: TransactionServiceError.self) {
            try commands.softDeleteTransaction(uuid: tx.uuid)
        }
        #expect(!tx.isSoftDeleted) // 阻断生效，流水未被删
        tx.isSoftDeleted = true
        try f.context.save()
        #expect(throws: TransactionServiceError.self) {
            try commands.undoSoftDeleteTransaction(uuid: tx.uuid)
        }
    }
}
