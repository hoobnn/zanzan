import Foundation
import SwiftData

/// 资产/账户（数据库设计文档 5.2）。当前余额 = 期初 + 流水派生，不落库。
@Model
final class StoredAccount {
    #Index<StoredAccount>([\.uuid])

    var uuid: UUID = UUID()
    var name: String = ""
    var subtitle: String = ""
    var kindRawValue: String = ""
    var iconKindRawValue: String = ""
    var iconPrimary: String = ""
    var iconSecondary: String = ""
    var iconIndex: Int = 0
    var currencyCode: String = "CNY"
    var initialBalanceMinorUnits: Int = 0
    var creditLimitMinorUnits: Int? = nil
    var creditPoolID: UUID? = nil
    var statementDay: Int? = nil
    var paymentDueDay: Int? = nil
    var note: String = ""
    var isIncludedInNetWorth: Bool = true
    var isSelectableForRecord: Bool = true
    var isArchived: Bool = false
    var sortOrder: Int = 0
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    /// 收支流水 + 转账转出方（inverse of StoredTransaction.account）
    @Relationship(deleteRule: .nullify, inverse: \StoredTransaction.account)
    var transactions: [StoredTransaction]? = nil

    /// 转账转入方反查（inverse of StoredTransaction.targetAccount）
    @Relationship(deleteRule: .nullify, inverse: \StoredTransaction.targetAccount)
    var incomingTransfers: [StoredTransaction]? = nil

    /// 语义类枚举：未知值返回 nil，禁回写兜底（设计文档 §4 前向兼容）
    var kind: AccountKind? { AccountKind(rawValue: kindRawValue) }

    init(name: String, kind: AccountKind) {
        self.name = name
        self.kindRawValue = kind.rawValue
    }
}
