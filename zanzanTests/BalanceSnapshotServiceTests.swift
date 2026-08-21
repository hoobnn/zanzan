import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct BalanceSnapshotServiceTests {
    /// 固定业务时间基点（逻辑内禁用 .now）
    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private static func at(_ hours: Int) -> Date { t0.addingTimeInterval(TimeInterval(hours) * 3_600) }

    /// 现金账户（期初 10000）+ 三笔活跃流水 + 一笔软删流水，转入对手方储蓄卡
    private func makeFixture(context: ModelContext) throws -> (cash: Account, card: Account) {
        let ledgerID = UUID()
        let cash = Account(name: "现金", kind: .fund)
        cash.initialBalanceMinorUnits = 10_000
        let card = Account(name: "储蓄卡", kind: .fund)
        context.insert(cash)
        context.insert(card)

        let expense = Transaction(kind: .expense, amountMinorUnits: 1_000, occurredAt: Self.at(1), ledgerID: ledgerID)
        expense.account = cash
        let income = Transaction(kind: .income, amountMinorUnits: 5_000, occurredAt: Self.at(2), ledgerID: ledgerID)
        income.account = cash
        income.feeMinorUnits = 100
        let transfer = Transaction(kind: .transfer, amountMinorUnits: 2_000, occurredAt: Self.at(3), ledgerID: ledgerID)
        transfer.account = cash
        transfer.targetAccount = card
        transfer.feeMinorUnits = 50
        let deleted = Transaction(kind: .expense, amountMinorUnits: 9_999, occurredAt: Self.at(3), ledgerID: ledgerID)
        deleted.account = cash
        deleted.isSoftDeleted = true
        for tx in [expense, income, transfer, deleted] { context.insert(tx) }
        try context.save()
        return (cash, card)
    }

    private func activeSnapshots(of accountUUID: UUID, in context: ModelContext) throws -> [BalanceSnapshot] {
        try context.fetch(FetchDescriptor<BalanceSnapshot>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.accountID == accountUUID }
        ))
    }

    // MARK: - 生成正确性

    @Test func 快照值与Provider全量派生一致() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let (cash, card) = try makeFixture(context: context)
        let service = BalanceSnapshotService(context: context)

        let cashSnapshot = try service.generateSnapshot(accountUUID: cash.uuid, asOf: Self.at(4))
        let cardSnapshot = try service.generateSnapshot(accountUUID: card.uuid, asOf: Self.at(4))

        let provider = AccountBalanceProvider(context: context)
        #expect(cashSnapshot.balanceMinorUnits == (try provider.balanceMinorUnits(of: cash)))
        #expect(cardSnapshot.balanceMinorUnits == (try provider.balanceMinorUnits(of: card)))
        // 现金：10000 − 1000 + (5000−100) − (2050) = 11850；软删流水不计
        #expect(cashSnapshot.balanceMinorUnits == 11_850)
        #expect(cardSnapshot.balanceMinorUnits == 2_000)
        #expect(cashSnapshot.fxRateToBase == nil) // CNY 账户恒 nil
    }

    @Test func 快照按asOf时点截断只计之前流水() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let (cash, _) = try makeFixture(context: context)
        let service = BalanceSnapshotService(context: context)

        // asOf = t+2：转账（t+3）尚未发生 → 10000 − 1000 + 4900 = 13900
        let snapshot = try service.generateSnapshot(accountUUID: cash.uuid, asOf: Self.at(2))
        #expect(snapshot.balanceMinorUnits == 13_900)
    }

    @Test func 外币历史快照同时截断未来余额与未来汇率() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let account = Account(name: "美元卡", kind: .fund)
        account.currencyCode = "USD"
        account.initialBalanceMinorUnits = 10_000
        context.insert(account)

        let past = Transaction(
            kind: .income,
            amountMinorUnits: 1_000,
            occurredAt: Self.at(1),
            ledgerID: UUID()
        )
        past.account = account
        past.currencyCode = "USD"
        past.fxRateToBase = Decimal(string: "7.00")
        let future = Transaction(
            kind: .expense,
            amountMinorUnits: 5_000,
            occurredAt: Self.at(3),
            ledgerID: UUID()
        )
        future.account = account
        future.currencyCode = "USD"
        future.fxRateToBase = Decimal(string: "7.50")
        context.insert(past)
        context.insert(future)
        try context.save()

        let snapshot = try BalanceSnapshotService(context: context)
            .generateSnapshot(accountUUID: account.uuid, asOf: Self.at(2))
        #expect(snapshot.balanceMinorUnits == 11_000)
        #expect(snapshot.fxRateToBase == Decimal(string: "7.00"))
    }

    @Test func 快照余额聚合溢出抛MoneyArithmeticError且不留半成品() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let account = Account(name: "极值账户", kind: .fund)
        account.initialBalanceMinorUnits = Int.max
        context.insert(account)
        let income = Transaction(
            kind: .income,
            amountMinorUnits: 1,
            occurredAt: Self.at(1),
            ledgerID: UUID()
        )
        income.account = account
        context.insert(income)
        try context.save()

        #expect(throws: MoneyArithmeticError.self) {
            try BalanceSnapshotService(context: context)
                .generateSnapshot(accountUUID: account.uuid, asOf: Self.at(2))
        }
        #expect(try context.fetchCount(FetchDescriptor<BalanceSnapshot>()) == 0)
    }

    // MARK: - 幂等

    @Test func 同账户同时点重复生成不新增行() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let (cash, _) = try makeFixture(context: context)
        let service = BalanceSnapshotService(context: context)

        let asOf = Self.at(4)
        try service.generateSnapshot(accountUUID: cash.uuid, asOf: asOf)
        try service.generateSnapshot(accountUUID: cash.uuid, asOf: asOf)

        let snapshots = try activeSnapshots(of: cash.uuid, in: context)
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.balanceMinorUnits == 11_850)
    }

    @Test func 同时点快照被软删后重建为新行() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let (cash, _) = try makeFixture(context: context)
        let service = BalanceSnapshotService(context: context)

        let asOf = Self.at(4)
        let first = try service.generateSnapshot(accountUUID: cash.uuid, asOf: asOf)
        first.isSoftDeleted = true // 模拟失效级联软删
        try context.save()

        let rebuilt = try service.generateSnapshot(accountUUID: cash.uuid, asOf: asOf)
        #expect(rebuilt.uuid != first.uuid) // 软删行不复用（§4 软删口径）
        #expect(try activeSnapshots(of: cash.uuid, in: context).count == 1)
    }

    // MARK: - 软删账户边界

    @Test func 软删账户不生成快照() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let account = Account(name: "已删", kind: .fund)
        account.isSoftDeleted = true
        context.insert(account)
        try context.save()

        let service = BalanceSnapshotService(context: context)
        #expect(throws: BalanceSnapshotServiceError.accountNotFound) {
            try service.generateSnapshot(accountUUID: account.uuid, asOf: Self.at(1))
        }
    }

    @Test func 批量生成跳过软删账户() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let (cash, card) = try makeFixture(context: context)
        let deleted = Account(name: "已删", kind: .fund)
        deleted.isSoftDeleted = true
        context.insert(deleted)
        try context.save()

        let service = BalanceSnapshotService(context: context)
        let snapshots = try service.generateSnapshots(asOf: Self.at(4))

        let accountIDs = Set(snapshots.map(\.accountID))
        #expect(accountIDs == [cash.uuid, card.uuid])
        #expect(try activeSnapshots(of: deleted.uuid, in: context).isEmpty)
    }

    @Test func 批量第二账户溢出后上下文无快照变更() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let valid = Account(name: "正常账户", kind: .fund)
        valid.sortOrder = 0
        let overflow = Account(name: "溢出账户", kind: .fund)
        overflow.sortOrder = 1
        overflow.initialBalanceMinorUnits = Int.max
        let income = Transaction(
            kind: .income,
            amountMinorUnits: 1,
            occurredAt: Self.at(1),
            ledgerID: UUID()
        )
        income.account = overflow
        context.insert(valid)
        context.insert(overflow)
        context.insert(income)
        try context.save()

        #expect(throws: MoneyArithmeticError.self) {
            try BalanceSnapshotService(context: context).generateSnapshots(asOf: Self.at(2))
        }
        #expect(try context.fetchCount(FetchDescriptor<BalanceSnapshot>()) == 0)
    }

    @Test func 脏快照全量重建后逐分收敛() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let (cash, card) = try makeFixture(context: context)
        let service = BalanceSnapshotService(context: context)
        let asOf = Self.at(4)
        let corrupt = try service.generateSnapshot(accountUUID: cash.uuid, asOf: asOf)
        corrupt.balanceMinorUnits = -1
        try context.save()

        let rebuilt = try service.rebuildAllSnapshots(asOf: asOf)
        #expect(rebuilt.count == 2)
        #expect(corrupt.isSoftDeleted)
        #expect(
            try AccountBalanceProvider(context: context)
                .balanceMinorUnits(of: cash, asOf: asOf) == 11_850
        )
        #expect(
            try AccountBalanceProvider(context: context)
                .balanceMinorUnits(of: card, asOf: asOf) == 2_000
        )
    }

    // MARK: - 一致性校验

    @Test func 一致性校验_快照加增量与全量派生一致() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let (cash, _) = try makeFixture(context: context)
        let service = BalanceSnapshotService(context: context)

        // 在 t+2 落快照，t+3 的转账走增量路径
        try service.generateSnapshot(accountUUID: cash.uuid, asOf: Self.at(2))
        let report = try service.verifyConsistency(accountUUID: cash.uuid)

        #expect(report.isConsistent)
        #expect(report.deviationMinorUnits == 0)
        #expect(report.derivedBalanceMinorUnits == 11_850)
        #expect(report.snapshotBalanceMinorUnits == 11_850)
        #expect(report.latestSnapshotAt == Self.at(2))
    }

    @Test func 一致性校验_脏快照报告偏差不修数据() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let (cash, _) = try makeFixture(context: context)
        let service = BalanceSnapshotService(context: context)

        let snapshot = try service.generateSnapshot(accountUUID: cash.uuid, asOf: Self.at(2))
        snapshot.balanceMinorUnits += 500 // 直接改快照值构造不一致
        try context.save()

        let report = try service.verifyConsistency(accountUUID: cash.uuid)
        #expect(!report.isConsistent)
        #expect(report.deviationMinorUnits == 500)
        #expect(report.derivedBalanceMinorUnits == 11_850)
        #expect(report.snapshotBalanceMinorUnits == 12_350)
        // 只报告不修：脏值原样保留（快照时点余额 13900 + 500）
        #expect(snapshot.balanceMinorUnits == 14_400)
    }

    // MARK: - 失效级联（§5.13 写路径挂接）

    /// 走服务写路径的夹具：账本 + 支出分类 + 现金账户（期初 10000）
    private func makeServiceFixture(context: ModelContext) throws -> (ledger: Ledger, cash: Account, dining: Category) {
        let ledger = try LedgerService(context: context).createLedger(LedgerDraft(name: "日常"))
        let cash = Account(name: "现金", kind: .fund)
        cash.initialBalanceMinorUnits = 10_000
        let dining = Category(name: "餐饮", kind: .expense, sortOrder: 0)
        context.insert(cash)
        context.insert(dining)
        try context.save()
        return (ledger, cash, dining)
    }

    private func expenseDraft(account: Account, category: Category, occurredAt: Date) -> TransactionDraft {
        var draft = TransactionDraft()
        draft.kind = .expense
        draft.amountString = "10"
        draft.occurredAt = occurredAt
        draft.accountUUID = account.uuid
        draft.categoryUUID = category.uuid
        return draft
    }

    @Test func 记早于快照的流水使快照失效_晚于则保留() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let (ledger, cash, dining) = try makeServiceFixture(context: context)
        try BalanceSnapshotService(context: context).generateSnapshot(accountUUID: cash.uuid, asOf: Self.at(4))
        let service = TransactionService(context: context)

        _ = try service.recordTransaction(
            expenseDraft(account: cash, category: dining, occurredAt: Self.at(6)), ledgerID: ledger.uuid
        )
        #expect(try activeSnapshots(of: cash.uuid, in: context).count == 1) // 晚于快照时点，保留

        _ = try service.recordTransaction(
            expenseDraft(account: cash, category: dining, occurredAt: Self.at(1)), ledgerID: ledger.uuid
        )
        #expect(try activeSnapshots(of: cash.uuid, in: context).isEmpty) // 早于快照时点，失效
    }

    @Test func 编辑流水按新旧时点较早者失效快照() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let (ledger, cash, dining) = try makeServiceFixture(context: context)
        let service = TransactionService(context: context)
        let tx = try service.recordTransaction(
            expenseDraft(account: cash, category: dining, occurredAt: Self.at(6)), ledgerID: ledger.uuid
        )
        try BalanceSnapshotService(context: context).generateSnapshot(accountUUID: cash.uuid, asOf: Self.at(4))

        // 把流水从 t+6 挪到 t+2：min(旧, 新) = t+2 < 快照时点 t+4 → 失效
        try service.updateTransaction(
            uuid: tx.uuid, draft: expenseDraft(account: cash, category: dining, occurredAt: Self.at(2))
        )
        #expect(try activeSnapshots(of: cash.uuid, in: context).isEmpty)
    }

    @Test func 软删与恢复流水使时点后快照失效() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let (ledger, cash, dining) = try makeServiceFixture(context: context)
        let service = TransactionService(context: context)
        let snapshotService = BalanceSnapshotService(context: context)
        let tx = try service.recordTransaction(
            expenseDraft(account: cash, category: dining, occurredAt: Self.at(1)), ledgerID: ledger.uuid
        )

        try snapshotService.generateSnapshot(accountUUID: cash.uuid, asOf: Self.at(4))
        try service.softDeleteTransaction(uuid: tx.uuid)
        #expect(try activeSnapshots(of: cash.uuid, in: context).isEmpty)

        try snapshotService.generateSnapshot(accountUUID: cash.uuid, asOf: Self.at(4))
        try service.undoSoftDeleteTransaction(uuid: tx.uuid)
        #expect(try activeSnapshots(of: cash.uuid, in: context).isEmpty)
    }

    @Test func 校准余额使时点后快照失效() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let (_, cash, _) = try makeServiceFixture(context: context)
        try BalanceSnapshotService(context: context).generateSnapshot(accountUUID: cash.uuid, asOf: Self.at(4))

        let adjustment = try AccountService(context: context).calibrateBalance(
            accountUUID: cash.uuid, actualBalanceMinorUnits: 20_000, occurredAt: Self.at(2)
        )
        #expect(adjustment != nil)
        #expect(try activeSnapshots(of: cash.uuid, in: context).isEmpty)
    }

    @Test func 改期初余额使全部快照失效() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let (_, cash, _) = try makeServiceFixture(context: context)
        let snapshotService = BalanceSnapshotService(context: context)
        try snapshotService.generateSnapshot(accountUUID: cash.uuid, asOf: Self.at(1))
        try snapshotService.generateSnapshot(accountUUID: cash.uuid, asOf: Self.at(4))

        // 不改期初：快照保留
        var draft = AccountDraft(account: cash)
        try AccountService(context: context).updateAccount(uuid: cash.uuid, draft: draft)
        #expect(try activeSnapshots(of: cash.uuid, in: context).count == 2)

        // 改期初：快照值 = 期初 + 增量，任意时点全脏 → 全部失效
        draft.initialBalanceString = "88"
        try AccountService(context: context).updateAccount(uuid: cash.uuid, draft: draft)
        #expect(try activeSnapshots(of: cash.uuid, in: context).isEmpty)
    }

    @Test func 一致性校验_无快照时视为一致() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let (cash, _) = try makeFixture(context: context)
        let service = BalanceSnapshotService(context: context)

        let report = try service.verifyConsistency(accountUUID: cash.uuid)
        #expect(report.isConsistent)
        #expect(report.latestSnapshotAt == nil)
        #expect(report.derivedBalanceMinorUnits == 11_850)
    }
}
