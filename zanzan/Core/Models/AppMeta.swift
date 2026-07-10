import Foundation
import SwiftData

/// 库级元数据键值——用途锁死为系统标记，业务数据禁入（数据库设计文档 5.15）
@Model
final class AppMeta {
    /// 业务主键，表间弱引用一律指向它
    var uuid: UUID = UUID()
    /// 键（如 schemaVersion）
    var key: String = ""
    /// 值
    var value: String = ""
    /// 软删除标记，全库无硬删除
    var isSoftDeleted: Bool = false
    /// 创建时间
    var createdAt: Date = Date.now
    /// 最后修改时间（命令层维护）
    var updatedAt: Date = Date.now

    init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}
