import Foundation
import SwiftData

/// V2：分期计划保存息费收取、取整与尾差规则；表数量不变。
enum SchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            Ledger.self,
            Account.self,
            Category.self,
            Transaction.self,
            Tag.self,
            TransactionLink.self,
            Budget.self,
            CreditPool.self,
            InstallmentPlan.self,
            InstallmentPeriod.self,
            RecurringRule.self,
            ImportBatch.self,
            BalanceSnapshot.self,
            AuditLog.self,
            AppMeta.self,
        ]
    }
}
