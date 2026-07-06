import Foundation
import SwiftData

/// 操作日志——只追加不更新，滚动保留由维护命令清理（数据库设计文档 5.14）
@Model
final class StoredAuditLog {
    var uuid: UUID = UUID()
    var action: String = ""
    var detail: String = ""
    var occurredAt: Date = Date.now
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(action: String, detail: String = "") {
        self.action = action
        self.detail = detail
    }
}
