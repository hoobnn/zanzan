import Foundation
import SwiftData

/// 银行授信池——多卡共享额度（数据库设计文档 5.8）。
/// 成员关系由 StoredAccount.creditPoolID 反向表达；已用/可用额度全部派生不落库。
@Model
final class StoredCreditPool {
    #Index<StoredCreditPool>([\.uuid])

    /// 业务主键，表间弱引用一律指向它
    var uuid: UUID = UUID()
    /// 池名（通常为银行名，如「招商银行」）
    var name: String = ""
    /// 总授信额度（分）
    var totalLimitMinorUnits: Int = 0
    /// 币种（成员账户币种须与池一致，命令层校验）
    var currencyCode: String = "CNY"
    /// 图标四件套：图标类型（通常取银行类素材）
    var iconKindRawValue: String = ""
    /// 图标四件套：主素材
    var iconPrimary: String = ""
    /// 图标四件套：副素材
    var iconSecondary: String = ""
    /// 图标四件套：备用序号
    var iconIndex: Int = 0
    /// 备注
    var note: String = ""
    /// 资产页池间排序
    var sortOrder: Int = 0
    /// 软删除标记，全库无硬删除
    var isSoftDeleted: Bool = false
    /// 创建时间
    var createdAt: Date = Date.now
    /// 最后修改时间（命令层维护）
    var updatedAt: Date = Date.now

    init(name: String, totalLimitMinorUnits: Int) {
        self.name = name
        self.totalLimitMinorUnits = totalLimitMinorUnits
    }
}
