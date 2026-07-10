import Foundation
import SwiftData

/// 操作日志——只追加不更新，滚动保留由维护命令清理（数据库设计文档 5.14）
@Model
final class AuditLog {
    /// 业务主键，表间弱引用一律指向它
    var uuid: UUID = UUID()
    /// 操作类型（如 accountDelete）
    var action: String = ""
    /// 详情
    var detail: String = ""
    /// 时间
    var occurredAt: Date = Date.now
    /// 软删除标记，全库无硬删除
    var isSoftDeleted: Bool = false
    /// 创建时间
    var createdAt: Date = Date.now
    /// 最后修改时间（命令层维护）
    var updatedAt: Date = Date.now

    init(action: String, detail: String = "") {
        self.action = action
        self.detail = detail
    }
}
