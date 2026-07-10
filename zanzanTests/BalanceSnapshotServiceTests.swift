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
