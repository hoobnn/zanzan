import Foundation
import SwiftData

/// 导入批次——误导入按批次反查、整批软删（数据库设计文档 5.12）
@Model
final class ImportBatch {
    /// 业务主键，表间弱引用一律指向它
    var uuid: UUID = UUID()
    /// 源文件名
    var fileName: String = ""
    var contentHash: String = "" // SHA-256，命令层撞哈希时警告疑似重复导入
    /// 导入流水数
    var transactionCount: Int = 0
    /// 导入时间
    var importedAt: Date = Date.now
    /// 软删除标记，全库无硬删除
    var isSoftDeleted: Bool = false
    /// 创建时间
    var createdAt: Date = Date.now
    /// 最后修改时间（命令层维护）
    var updatedAt: Date = Date.now

    init(fileName: String, importedAt: Date) {
        self.fileName = fileName
        self.importedAt = importedAt
    }
}
