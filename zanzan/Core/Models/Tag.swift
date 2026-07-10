import Foundation
import SwiftData

/// 标签，与流水原生多对多（数据库设计文档 5.6）
@Model
final class Tag {
    #Index<Tag>([\.uuid])

    /// 业务主键，表间弱引用一律指向它
    var uuid: UUID = UUID()
    /// 标签名
    var name: String = ""
    /// 颜色 token（与账本同一套）
    var colorID: String = "blue"
    /// 排序
    var sortOrder: Int = 0
    /// nil = 全局标签
    var ledgerID: UUID? = nil
    /// 归档（不可再挂新流水，既有引用与统计照常）
    var isArchived: Bool = false
    /// 软删除标记，全库无硬删除
    var isSoftDeleted: Bool = false
    /// 创建时间
    var createdAt: Date = Date.now
    /// 最后修改时间（命令层维护）
    var updatedAt: Date = Date.now

    @Relationship(deleteRule: .nullify, inverse: \Transaction.tags)
    var transactions: [Transaction]? = nil

    init(name: String) {
        self.name = name
    }
}
