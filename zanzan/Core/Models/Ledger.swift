import Foundation
import SwiftData

/// 账本（数据库设计文档 5.1）
@Model
final class Ledger {
    #Index<Ledger>([\.uuid])

    /// 业务主键，表间弱引用一律指向它
    var uuid: UUID = UUID()
    /// 账本名
    var name: String = ""
    /// 是否默认账本（有且仅有一本，命令层保证）
    var isDefault: Bool = false
    /// 图标四件套：图标类型
    var iconKindRawValue: String = ""
    /// 图标四件套：主素材
    var iconPrimary: String = ""
    /// 图标四件套：副素材
    var iconSecondary: String = ""
    /// 图标四件套：备用序号
    var iconIndex: Int = 0
    /// 主题色 token
    var colorID: String = "blue"
    /// 归档（切换器折叠，数据照常可看，见设计文档 §4 归档语义）
    var isArchived: Bool = false
    /// 账本切换器排序
    var sortOrder: Int = 0
    /// 软删除标记，全库无硬删除
    var isSoftDeleted: Bool = false
    /// 创建时间
    var createdAt: Date = Date.now
    /// 最后修改时间（命令层维护）
    var updatedAt: Date = Date.now

    init(name: String) {
        self.name = name
    }
}
