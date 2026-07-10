import Foundation
import SwiftData

/// 账户余额派生（设计文档 §4 派生优先：余额不落库）。
/// ponytail: 全量流水求和，账户流水到万条量级再上 StoredBalanceSnapshot 检查点加速。
struct AccountBalanceProjector {
    let context: ModelContext

    func balanceMinorUnits(of account: StoredAccount) throws -> Int {
        let uuid = account.uuid
        let descriptor = FetchDescriptor<StoredTransaction>(
            predicate: #Predicate {
                !$0.isSoftDeleted && ($0.account?.uuid == uuid || $0.targetAccount?.uuid == uuid)
            }
        )
        let transactions = try context.fetch(descriptor)
        return transactions.reduce(account.initialBalanceMinorUnits) {
            $0 + $1.balanceDeltaMinorUnits(for: uuid)
        }
    }
}
