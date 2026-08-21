import Foundation
import SwiftData

/// 余额检查点维护命令（设计文档 5.13）：落快照 + 全量重算一致性校验。
/// 快照只是缓存；校验发现不一致只报告，不自动修数据。
struct BalanceSnapshotService {
    let context: ModelContext

    /// 为单个账户在 asOf 时点落快照。
    /// 同账户同时点已有活跃快照则刷新其值（幂等，不新增行）；软删账户不生成。
    @discardableResult
    func generateSnapshot(accountUUID: UUID, asOf: Date) throws -> BalanceSnapshot {
        do {
            let account = try fetchActiveAccount(accountUUID)
            let snapshot = try upsertSnapshot(for: account, asOf: asOf)
            try context.zanzanSave()
            return snapshot
        } catch {
            context.rollback()
            throw error
        }
    }

    /// 全部未软删账户批量落快照（归档账户余额照常，一并生成）。
    @discardableResult
    func generateSnapshots(asOf: Date) throws -> [BalanceSnapshot] {
        do {
            let accounts = try context.fetch(
                FetchDescriptor<Account>(
                    predicate: #Predicate { !$0.isSoftDeleted },
                    sortBy: [SortDescriptor(\.sortOrder)]
                )
            )
            let snapshots = try accounts.map { try upsertSnapshot(for: $0, asOf: asOf) }
            try context.zanzanSave()
            return snapshots
        } catch {
            context.rollback()
            throw error
        }
    }

    /// 软删全部活跃快照并按指定时点一次性重建；任一账户失败则整批回滚。
    @discardableResult
    func rebuildAllSnapshots(asOf: Date) throws -> [BalanceSnapshot] {
        do {
            let rebuiltAt = Date.now
            for snapshot in try context.fetch(
                FetchDescriptor<BalanceSnapshot>(predicate: #Predicate { !$0.isSoftDeleted })
            ) {
                snapshot.isSoftDeleted = true
                snapshot.updatedAt = rebuiltAt
            }
            let accounts = try context.fetch(
                FetchDescriptor<Account>(
                    predicate: #Predicate { !$0.isSoftDeleted },
                    sortBy: [SortDescriptor(\.sortOrder)]
                )
            )
            let rebuilt = try accounts.map { try upsertSnapshot(for: $0, asOf: asOf) }
            try context.zanzanSave()
            return rebuilt
        } catch {
            context.rollback()
            throw error
        }
    }

    /// 全量重算一致性校验：全量派生余额（真相） vs 最新活跃快照 + 之后流水增量。
    /// 无快照时两条路径恒等，视为一致。
    func verifyConsistency(accountUUID: UUID, asOf: Date = .now) throws -> BalanceConsistencyReport {
        let account = try fetchActiveAccount(accountUUID)
        let derived = try AccountBalanceProvider(context: context)
            .fullyDerivedBalanceMinorUnits(of: account, asOf: asOf)

        var snapshotDescriptor = FetchDescriptor<BalanceSnapshot>(
            predicate: #Predicate {
                !$0.isSoftDeleted && $0.accountID == accountUUID && $0.snapshotAt <= asOf
            },
            sortBy: [SortDescriptor(\.snapshotAt, order: .reverse)]
        )
        snapshotDescriptor.fetchLimit = 1
        guard let latest = try context.fetch(snapshotDescriptor).first else {
            return BalanceConsistencyReport(
                derivedBalanceMinorUnits: derived,
                snapshotBalanceMinorUnits: derived,
                latestSnapshotAt: nil,
                deviationMinorUnits: 0
            )
        }

        let uuid = account.uuid
        let snapshotAt = latest.snapshotAt
        let laterTransactions = try context.fetch(
            FetchDescriptor<Transaction>(predicate: #Predicate {
                !$0.isSoftDeleted && $0.occurredAt > snapshotAt
                    && $0.occurredAt <= asOf
                    && ($0.account?.uuid == uuid || $0.targetAccount?.uuid == uuid)
            })
        )
        let incremental = try laterTransactions.reduce(latest.balanceMinorUnits) {
            try MoneyArithmetic.add($0, $1.checkedBalanceDeltaMinorUnits(for: uuid))
        }
        return BalanceConsistencyReport(
            derivedBalanceMinorUnits: derived,
            snapshotBalanceMinorUnits: incremental,
            latestSnapshotAt: snapshotAt,
            deviationMinorUnits: try MoneyArithmetic.subtract(incremental, derived)
        )
    }

    // MARK: - 失效级联（§5.13）

    /// 软删受影响账户 `snapshotAt >= 时点` 的活跃快照。写路径动了历史（记/改/删/恢复流水、
    /// 校准余额、改期初余额）即调用——快照正确性的前提是「时点之前的流水没变过」，
    /// 宁可少快照不可留脏快照（§5.13 明文）。静态助手不 save：快照只是缓存，
    /// 随调用方业务写一并提交即可，不要求同一事务原子（多删无害）。
    static func invalidateSnapshots(accountUUIDs: Set<UUID>, onOrAfter date: Date, context: ModelContext) throws {
        for accountID in accountUUIDs {
            let snapshots = try context.fetch(FetchDescriptor<BalanceSnapshot>(
                predicate: #Predicate { !$0.isSoftDeleted && $0.accountID == accountID && $0.snapshotAt >= date }
            ))
            for snapshot in snapshots {
                snapshot.isSoftDeleted = true
                snapshot.updatedAt = .now
            }
        }
    }

    // MARK: - 私有

    /// 落/刷新一笔快照（不 save，由公开入口统一提交）。
    private func upsertSnapshot(for account: Account, asOf: Date) throws -> BalanceSnapshot {
        let balance = try AccountBalanceProvider(context: context)
            .fullyDerivedBalanceMinorUnits(of: account, asOf: asOf)
        let fxRate = try fxRateToBase(for: account, asOf: asOf)

        let uuid = account.uuid
        var descriptor = FetchDescriptor<BalanceSnapshot>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.accountID == uuid && $0.snapshotAt == asOf }
        )
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            existing.balanceMinorUnits = balance
            existing.fxRateToBase = fxRate
            existing.updatedAt = .now // 审计时间，非业务时间，随写路径惯例
            return existing
        }

        let snapshot = BalanceSnapshot(accountID: uuid, snapshotAt: asOf, balanceMinorUnits: balance)
        snapshot.fxRateToBase = fxRate
        context.insert(snapshot)
        return snapshot
    }

    /// 快照时点汇率（设计文档 5.13）：取该币种 asOf 前最近一笔流水的汇率快照；CNY 账户恒 nil。
    private func fxRateToBase(for account: Account, asOf: Date) throws -> Decimal? {
        let currency = account.currencyCode
        guard currency != "CNY" else { return nil }
        var descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate {
                !$0.isSoftDeleted && $0.currencyCode == currency
                    && $0.occurredAt <= asOf && $0.fxRateToBase != nil
            },
            sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.fxRateToBase
    }

    private func fetchActiveAccount(_ uuid: UUID) throws -> Account {
        let descriptor = FetchDescriptor<Account>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        )
        guard let account = try context.fetch(descriptor).first else {
            throw BalanceSnapshotServiceError.accountNotFound
        }
        return account
    }
}

/// 一致性校验结果：只报告，不修数据。
struct BalanceConsistencyReport {
    /// 全量派生余额（数据真相：期初 + 全部活跃流水）
    let derivedBalanceMinorUnits: Int
    /// 快照路径余额：最新活跃快照 + 之后流水增量；无快照时等于全量派生
    let snapshotBalanceMinorUnits: Int
    /// 参与比对的最新快照时点；nil = 该账户无活跃快照
    let latestSnapshotAt: Date?

    /// 偏差 = 快照路径 − 全量派生（分）
    let deviationMinorUnits: Int
    var isConsistent: Bool { deviationMinorUnits == 0 }
}

enum BalanceSnapshotServiceError: LocalizedError {
    case accountNotFound

    var errorDescription: String? {
        switch self {
        case .accountNotFound: ZanzanLocalization.string( "账户不存在或已删除")
        }
    }
}
