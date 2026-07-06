import Foundation
import SwiftData

/// 银行授信池——多卡共享额度（数据库设计文档 5.8）。
/// 成员关系由 StoredAccount.creditPoolID 反向表达；已用/可用额度全部派生不落库。
@Model
final class StoredCreditPool {
    #Index<StoredCreditPool>([\.uuid])

    var uuid: UUID = UUID()
    var name: String = ""
    var totalLimitMinorUnits: Int = 0
    var currencyCode: String = "CNY"
    var iconKindRawValue: String = ""
    var iconPrimary: String = ""
    var iconSecondary: String = ""
    var iconIndex: Int = 0
    var note: String = ""
    var sortOrder: Int = 0
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(name: String, totalLimitMinorUnits: Int) {
        self.name = name
        self.totalLimitMinorUnits = totalLimitMinorUnits
    }
}
