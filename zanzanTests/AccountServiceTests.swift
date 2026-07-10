import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct AccountServiceTests {
    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    @Test func 创建账户解析期初余额() throws {
        let context = try makeContext()
        var draft = AccountDraft()
        draft.name = "招行储蓄卡"
        draft.subtitle = "招商银行"
        draft.kind = .fund
        draft.initialBalanceString = "1234.56"
        let account = try AccountService(context: context).createAccount(draft)
        #expect(account.initialBalanceMinorUnits == 123_456)
        #expect(account.kind == .fund)
        #expect(account.currencyCode == "CNY")
    }

    @Test func 期初余额允许负数() throws {
        let context = try makeContext()
        var draft = AccountDraft()
        draft.name = "信用卡"
        draft.kind = .credit
        draft.initialBalanceString = "-500"
        let account = try AccountService(context: context).createAccount(draft)
        #expect(account.initialBalanceMinorUnits == -50_000)
    }

    @Test func 非credit类清空信用字段() throws {
        var draft = AccountDraft()
        draft.name = "现金"
        draft.kind = .fund
        draft.creditLimitString = "10000"
        draft.statementDay = 5
        draft.paymentDueDay = 25
        let validated = try draft.validated()
        #expect(validated.creditLimitMinorUnits == nil)
        #expect(validated.statementDay == nil)
        #expect(validated.paymentDueDay == nil)
    }

    @Test func 账单日越界被拒() throws {
        var draft = AccountDraft()
        draft.name = "信用卡"
        draft.kind = .credit
        draft.statementDay = 29
        #expect(throws: AccountDraftError.self) { _ = try draft.validated() }
    }

    @Test func 空名被拒() throws {
        var draft = AccountDraft()
        draft.name = " "
        #expect(throws: AccountDraftError.self) { _ = try draft.validated() }
    }

    @Test func 有活跃流水引用阻断删除含转入方() throws {
        let context = try makeContext()
        let commands = AccountService(context: context)
        var draft = AccountDraft()
        draft.name = "现金"
        let source = try commands.createAccount(draft)
        draft.name = "储蓄卡"
        let target = try commands.createAccount(draft)
        let tx = Transaction(kind: .transfer, amountMinorUnits: 100, occurredAt: .now, ledgerID: UUID())
        tx.account = source
        tx.targetAccount = target
        context.insert(tx)
        try context.save()
        #expect(throws: AccountServiceError.self) { try commands.softDeleteAccount(uuid: source.uuid) }
        #expect(throws: AccountServiceError.self) { try commands.softDeleteAccount(uuid: target.uuid) }
    }

    @Test func 删除级联软删余额快照() throws {
        let context = try makeContext()
        let commands = AccountService(context: context)
        var draft = AccountDraft()
        draft.name = "现金"
        let account = try commands.createAccount(draft)
        let snapshot = BalanceSnapshot(accountID: account.uuid, snapshotAt: .now, balanceMinorUnits: 100)
        context.insert(snapshot)
        try context.save()
        try commands.softDeleteAccount(uuid: account.uuid)
        #expect(account.isSoftDeleted)
        #expect(snapshot.isSoftDeleted)
    }

    @Test func 归档切换() throws {
        let context = try makeContext()
        let commands = AccountService(context: context)
        var draft = AccountDraft()
        draft.name = "公积金"
        let account = try commands.createAccount(draft)
        try commands.setArchived(uuid: account.uuid, isArchived: true)
        #expect(account.isArchived)
        try commands.setArchived(uuid: account.uuid, isArchived: false)
        #expect(!account.isArchived)
    }
}
