import Foundation
import SwiftData

/// 收支分类，自引用两级树经 parentID 弱引用表达（数据库设计文档 5.3）
@Model
final class StoredCategory {
    #Index<StoredCategory>([\.uuid])

    var uuid: UUID = UUID()
    var name: String = ""
    var kindRawValue: String = ""
    var iconKindRawValue: String = ""
    var iconPrimary: String = ""
    var iconSecondary: String = ""
    var iconIndex: Int = 0
    var sortOrder: Int = 0
    var parentID: UUID? = nil
    var ledgerID: UUID? = nil
    var isBuiltIn: Bool = false
    var isArchived: Bool = false
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
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
