import Foundation
import SwiftData

/// 收支分类，自引用两级树经 parentID 弱引用表达（数据库设计文档 5.3）
@Model
final class StoredCategory {
    #Index<StoredCategory>([\.uuid])

    /// 业务主键，表间弱引用一律指向它
    var uuid: UUID = UUID()
    /// 分类名
    var name: String = ""
    /// 方向：expense / income
    var kindRawValue: String = ""
    /// 图标四件套：图标类型
    var iconKindRawValue: String = ""
    /// 图标四件套：主素材
    var iconPrimary: String = ""
    /// 图标四件套：副素材
    var iconSecondary: String = ""
    /// 图标四件套：备用序号
    var iconIndex: Int = 0
    /// 同层排序
    var sortOrder: Int = 0
    /// nil = 一级分类；否则指向父分类（两级树，命令层禁止三级）
    var parentID: UUID? = nil
    /// nil = 全局分类；非 nil = 账本专属分类
    var ledgerID: UUID? = nil
    /// 系统预置（seed 注入；「恢复默认分类」按此识别）
    var isBuiltIn: Bool = false
    /// 归档（记账不可选，历史统计照常）；归档父分类连带子分类不可选
    var isArchived: Bool = false
    /// 软删除标记，全库无硬删除
    var isSoftDeleted: Bool = false
    /// 创建时间
    var createdAt: Date = Date.now
    /// 最后修改时间（命令层维护）
    var updatedAt: Date = Date.now

    @Relationship(deleteRule: .nullify, inverse: \StoredTransaction.category)
    var transactions: [StoredTransaction]? = nil

    /// 方向仅 expense/income 合法（命令层校验），transfer 不挂分类
    var kind: TransactionKind? { TransactionKind(rawValue: kindRawValue) }

    init(name: String, kind: TransactionKind, sortOrder: Int) {
        self.name = name
        self.kindRawValue = kind.rawValue
        self.sortOrder = sortOrder
    }
}
