import Foundation
import SwiftData

/// 标签，与流水原生多对多（数据库设计文档 5.6）
@Model
final class StoredTag {
    #Index<StoredTag>([\.uuid])

    var uuid: UUID = UUID()
    var name: String = ""
    var colorID: String = "blue"
    var sortOrder: Int = 0
    var ledgerID: UUID? = nil
    var isArchived: Bool = false
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    @Relationship(deleteRule: .nullify, inverse: \StoredTransaction.tags)
    var transactions: [StoredTransaction]? = nil

    init(name: String) {
        self.name = name
    }
}
