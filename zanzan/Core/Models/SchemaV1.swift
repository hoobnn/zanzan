import Foundation
import SwiftData

/// 版本登记簿 V1（数据库设计文档 13.1）
enum SchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            StoredLedger.self,
            StoredAccount.self,
            StoredCategory.self,
            StoredTransaction.self,
            StoredTag.self,
            StoredTransactionLink.self,
            StoredBudget.self,
            StoredCreditPool.self,
        ]
    }
}
