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

    // MARK: - 余额校准

    private func makeAccountWithLedger(
        context: ModelContext, initialBalance: String = "100"
    ) throws -> Account {
        let ledger = Ledger(name: "默认账本")
        ledger.isDefault = true
        context.insert(ledger)
        var draft = AccountDraft()
        draft.name = "理财"
        draft.kind = .investment
        draft.initialBalanceString = initialBalance
        return try AccountService(context: context).createAccount(draft)
    }

    @Test func 校准生成adjustment流水且余额闭环() throws {
        let context = try makeContext()
        let account = try makeAccountWithLedger(context: context, initialBalance: "100") // 10000 分
        let tx = try AccountService(context: context)
            .calibrateBalance(accountUUID: account.uuid, actualBalanceMinorUnits: 12_345)
        let unwrapped = try #require(tx)
        #expect(unwrapped.kind == .income)
        #expect(unwrapped.amountMinorUnits == 2_345)
        #expect(unwrapped.sourceKind == .adjustment)
        #expect(unwrapped.isExcludedFromStats)
        #expect(unwrapped.ledgerID != nil)
        let derived = try AccountBalanceProvider(context: context).balanceMinorUnits(of: account)
        #expect(derived == 12_345)
    }

    @Test func 零差额不生成流水() throws {
        let context = try makeContext()
        let account = try makeAccountWithLedger(context: context, initialBalance: "100")
        let tx = try AccountService(context: context)
            .calibrateBalance(accountUUID: account.uuid, actualBalanceMinorUnits: 10_000)
        #expect(tx == nil)
        let count = try context.fetchCount(FetchDescriptor<Transaction>())
        #expect(count == 0)
    }

    @Test func 负差额生成支出流水向下校准() throws {
        let context = try makeContext()
        let account = try makeAccountWithLedger(context: context, initialBalance: "100")
        let tx = try AccountService(context: context)
            .calibrateBalance(accountUUID: account.uuid, actualBalanceMinorUnits: 8_000)
        let unwrapped = try #require(tx)
        #expect(unwrapped.kind == .expense)
        #expect(unwrapped.amountMinorUnits == 2_000)
        let derived = try AccountBalanceProvider(context: context).balanceMinorUnits(of: account)
        #expect(derived == 8_000)
    }

    @Test func 软删账户校准失败() throws {
        let context = try makeContext()
        let commands = AccountService(context: context)
        let account = try makeAccountWithLedger(context: context)
        try commands.softDeleteAccount(uuid: account.uuid)
        #expect(throws: AccountServiceError.self) {
            try commands.calibrateBalance(accountUUID: account.uuid, actualBalanceMinorUnits: 0)
        }
    }

    @Test func 归档账户校准失败() throws {
        let context = try makeContext()
        let commands = AccountService(context: context)
        let account = try makeAccountWithLedger(context: context)
        try commands.setArchived(uuid: account.uuid, isArchived: true)
        #expect(throws: AccountServiceError.self) {
            try commands.calibrateBalance(accountUUID: account.uuid, actualBalanceMinorUnits: 0)
        }
    }

    // MARK: - 多币种

    @Test func 币种归一化大写落库() throws {
        let context = try makeContext()
        var draft = AccountDraft()
        draft.name = "美元卡"
        draft.currencyCode = " usd "
        let account = try AccountService(context: context).createAccount(draft)
        #expect(account.currencyCode == "USD")
    }

    @Test func 非法币种被拒() throws {
        var draft = AccountDraft()
        draft.name = "外币卡"
        for code in ["US", "USDX", "US1", ""] {
            draft.currencyCode = code
            #expect(throws: AccountDraftError.self) { _ = try draft.validated() }
        }
    }

    @Test func 有流水账户禁改币种() throws {
        let context = try makeContext()
        let commands = AccountService(context: context)
        var draft = AccountDraft()
        draft.name = "现金"
        let account = try commands.createAccount(draft)
        let tx = Transaction(kind: .expense, amountMinorUnits: 100, occurredAt: .now, ledgerID: UUID())
        tx.account = account
        context.insert(tx)
        try context.save()
        draft.currencyCode = "USD"
        #expect(throws: AccountServiceError.self) {
            try commands.updateAccount(uuid: account.uuid, draft: draft)
        }
        // 软删流水同样阻断（恢复后币种口径仍须一致）
        tx.isSoftDeleted = true
        try context.save()
        #expect(throws: AccountServiceError.self) {
            try commands.updateAccount(uuid: account.uuid, draft: draft)
        }
        #expect(account.currencyCode == "CNY")
    }

    @Test func 无流水账户可改币种() throws {
        let context = try makeContext()
        let commands = AccountService(context: context)
        var draft = AccountDraft()
        draft.name = "现金"
        let account = try commands.createAccount(draft)
        draft.currencyCode = "USD"
        try commands.updateAccount(uuid: account.uuid, draft: draft)
        #expect(account.currencyCode == "USD")
    }

    @Test func 池内账户禁改币种() throws {
        let context = try makeContext()
        let commands = AccountService(context: context)
        var draft = AccountDraft()
        draft.name = "池内信用卡"
        draft.kind = .credit
        let account = try commands.createAccount(draft)
        account.creditPoolID = UUID() // 模拟已绑定授信池
        try context.save()

        draft.currencyCode = "USD" // 零流水也不许改：会破坏「成员币种与池一致」不变量（§5.8）
        #expect(throws: AccountServiceError.self) {
            try commands.updateAccount(uuid: account.uuid, draft: draft)
        }
        #expect(account.currencyCode == "CNY")
    }

    // MARK: - 外币校准

    private func makeUSDAccountWithLedger(context: ModelContext) throws -> Account {
        let ledger = Ledger(name: "默认账本")
        ledger.isDefault = true
        context.insert(ledger)
        var draft = AccountDraft()
        draft.name = "美元卡"
        draft.currencyCode = "USD"
        draft.initialBalanceString = "100"
        return try AccountService(context: context).createAccount(draft)
    }

    @Test func 外币校准显式汇率优先() throws {
        let context = try makeContext()
        let account = try makeUSDAccountWithLedger(context: context)
        let tx = try AccountService(context: context).calibrateBalance(
            accountUUID: account.uuid,
            actualBalanceMinorUnits: 12_000,
            fxRateToBase: Decimal(string: "7.25")!
        )
        let unwrapped = try #require(tx)
        #expect(unwrapped.currencyCode == "USD")
        #expect(unwrapped.fxRateToBase == Decimal(string: "7.25"))
        #expect(unwrapped.sourceKind == .adjustment)
    }

    @Test func 外币校准无显式汇率取最近快照() throws {
        let context = try makeContext()
        let account = try makeUSDAccountWithLedger(context: context)
        // 另一账户上的 USD 流水提供全库汇率快照（不影响本账户派生余额）
        let snapshotTx = Transaction(kind: .expense, amountMinorUnits: 100, occurredAt: .now, ledgerID: UUID())
        snapshotTx.currencyCode = "USD"
        snapshotTx.fxRateToBase = Decimal(string: "7.10")
        context.insert(snapshotTx)
        try context.save()
        let tx = try AccountService(context: context)
            .calibrateBalance(accountUUID: account.uuid, actualBalanceMinorUnits: 12_000)
        #expect(try #require(tx).fxRateToBase == Decimal(string: "7.10"))
    }

    @Test func 外币校准无汇率无快照抛错() throws {
        let context = try makeContext()
        let account = try makeUSDAccountWithLedger(context: context)
        #expect(throws: AccountServiceError.self) {
            try AccountService(context: context)
                .calibrateBalance(accountUUID: account.uuid, actualBalanceMinorUnits: 12_000)
        }
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
