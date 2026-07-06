import Foundation
import SwiftData

/// 账本（数据库设计文档 5.1）
@Model
final class StoredLedger {
    #Index<StoredLedger>([\.uuid])

    var uuid: UUID = UUID()
    var name: String = ""
    var isDefault: Bool = false
    var iconKindRawValue: String = ""
    var iconPrimary: String = ""
    var iconSecondary: String = ""
    var iconIndex: Int = 0
    var colorID: String = "blue"
    var isArchived: Bool = false
    var sortOrder: Int = 0
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(name: String) {
        self.name = name
    }
}
