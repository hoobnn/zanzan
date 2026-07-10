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
        let account = try fetchActiveAccount(accountUUID)
        let snapshot = try upsertSnapshot(for: account, asOf: asOf)
        try context.save()
        return snapshot
    }

    /// 全部未软删账户批量落快照（归档账户余额照常，一并生成）。
    @discardableResult
    func generateSnapshots(asOf: Date) throws -> [BalanceSnapshot] {
        let accounts = try context.fetch(
            FetchDescriptor<Account>(predicate: #Predicate { !$0.isSoftDeleted })
        )
        let snapshots = try accounts.map { try upsertSnapshot(for: $0, asOf: asOf) }
        try context.save()
        return snapshots
    }

    /// 全量重算一致性校验：全量派生余额（真相） vs 最新活跃快照 + 之后流水增量。
    /// 无快照时两条路径恒等，视为一致。
    func verifyConsistency(accountUUID: UUID) throws -> BalanceConsistencyReport {
        let account = try fetchActiveAccount(accountUUID)
        let derived = try AccountBalanceProvider(context: context).balanceMinorUnits(of: account)

        var snapshotDescriptor = FetchDescriptor<BalanceSnapshot>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.accountID == accountUUID },
            sortBy: [SortDescriptor(\.snapshotAt, order: .reverse)]
        )
        snapshotDescriptor.fetchLimit = 1
        guard let latest = try context.fetch(snapshotDescriptor).first else {
            return BalanceConsistencyReport(
                derivedBalanceMinorUnits: derived,
                snapshotBalanceMinorUnits: derived,
                latestSnapshotAt: nil
            )
        }

        let uuid = account.uuid
        let snapshotAt = latest.snapshotAt
        let laterTransactions = try context.fetch(
            FetchDescriptor<Transaction>(predicate: #Predicate {
                !$0.isSoftDeleted && $0.occurredAt > snapshotAt
                    && ($0.account?.uuid == uuid || $0.targetAccount?.uuid == uuid)
            })
        )
        let incremental = laterTransactions.reduce(latest.balanceMinorUnits) {
            $0 + $1.balanceDeltaMinorUnits(for: uuid)
        }
        return BalanceConsistencyReport(
            derivedBalanceMinorUnits: derived,
            snapshotBalanceMinorUnits: incremental,
            latestSnapshotAt: snapshotAt
        )
    }

    // MARK: - 私有

    /// 落/刷新一笔快照（不 save，由公开入口统一提交）。
    private func upsertSnapshot(for account: Account, asOf: Date) throws -> BalanceSnapshot {
        let balance = try balanceMinorUnits(of: account, asOf: asOf)
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

    /// asOf 时点派生余额：期初 + occurredAt ≤ asOf 的活跃流水增量。
    /// 口径与 AccountBalanceProvider 完全一致，仅多时点截断（Provider 无 asOf 参数，归属另一切片）。
    private func balanceMinorUnits(of account: Account, asOf: Date) throws -> Int {
        let uuid = account.uuid
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate {
                !$0.isSoftDeleted && $0.occurredAt <= asOf
                    && ($0.account?.uuid == uuid || $0.targetAccount?.uuid == uuid)
            }
        )
        let transactions = try context.fetch(descriptor)
        return transactions.reduce(account.initialBalanceMinorUnits) {
            $0 + $1.balanceDeltaMinorUnits(for: uuid)
        }
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
    var deviationMinorUnits: Int { snapshotBalanceMinorUnits - derivedBalanceMinorUnits }
    var isConsistent: Bool { deviationMinorUnits == 0 }
}

enum BalanceSnapshotServiceError: LocalizedError {
    case accountNotFound

    var errorDescription: String? {
        switch self {
        case .accountNotFound: String(localized: "账户不存在或已删除")
        }
    }
}
