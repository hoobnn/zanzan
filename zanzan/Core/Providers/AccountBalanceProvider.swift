import Foundation
import SwiftData

/// 账户余额派生（设计文档 §4 派生优先）：优先使用最近有效快照 + 后续流水，
/// 无快照时回落全量派生；快照永远只是可删光重建的查询缓存。
struct AccountBalanceProvider {
    let context: ModelContext

    /// `asOf` 之后的未来流水不影响当前/历史时点余额。
    func balanceMinorUnits(of account: Account, asOf: Date = .now) throws -> Int {
        let uuid = account.uuid
        var snapshotDescriptor = FetchDescriptor<BalanceSnapshot>(
            predicate: #Predicate {
                !$0.isSoftDeleted && $0.accountID == uuid && $0.snapshotAt <= asOf
            },
            sortBy: [SortDescriptor(\.snapshotAt, order: .reverse)]
        )
        snapshotDescriptor.fetchLimit = 1
        guard let snapshot = try context.fetch(snapshotDescriptor).first else {
            return try fullyDerivedBalanceMinorUnits(of: account, asOf: asOf)
        }
        return try balanceMinorUnits(
            of: account,
            after: snapshot.snapshotAt,
            through: asOf,
            startingAt: snapshot.balanceMinorUnits
        )
    }

    /// 维护/一致性校验使用的真值路径：忽略所有快照，从期初余额全量派生。
    func fullyDerivedBalanceMinorUnits(
        of account: Account,
        asOf: Date = .now
    ) throws -> Int {
        try balanceMinorUnits(
            of: account,
            after: nil,
            through: asOf,
            startingAt: account.initialBalanceMinorUnits
        )
    }

    private func balanceMinorUnits(
        of account: Account,
        after: Date?,
        through asOf: Date,
        startingAt initialBalance: Int
    ) throws -> Int {
        let uuid = account.uuid
        let descriptor: FetchDescriptor<Transaction>
        if let after {
            descriptor = FetchDescriptor<Transaction>(
                predicate: #Predicate {
                    !$0.isSoftDeleted && $0.occurredAt > after && $0.occurredAt <= asOf
                        && ($0.account?.uuid == uuid || $0.targetAccount?.uuid == uuid)
                }
            )
        } else {
            descriptor = FetchDescriptor<Transaction>(
                predicate: #Predicate {
                    !$0.isSoftDeleted && $0.occurredAt <= asOf
                        && ($0.account?.uuid == uuid || $0.targetAccount?.uuid == uuid)
                }
            )
        }
        let transactions = try context.fetch(descriptor)
        return try transactions.reduce(initialBalance) {
            try MoneyArithmetic.add($0, $1.checkedBalanceDeltaMinorUnits(for: uuid))
        }
    }
}
