import Foundation
import SwiftData

/// 库级元数据键值——用途锁死为系统标记，业务数据禁入（数据库设计文档 5.15）
@Model
final class StoredMeta {
    var uuid: UUID = UUID()
    var key: String = ""
    var value: String = ""
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}
