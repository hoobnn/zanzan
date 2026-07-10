import Foundation
import SwiftData

/// 版本登记簿 V1（数据库设计文档 13.1）——全部 15 张表
enum SchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

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
