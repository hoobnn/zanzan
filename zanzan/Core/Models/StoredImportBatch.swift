import Foundation
import SwiftData

/// 导入批次——误导入按批次反查、整批软删（数据库设计文档 5.12）
@Model
final class StoredImportBatch {
    var uuid: UUID = UUID()
    var fileName: String = ""
    var contentHash: String = "" // SHA-256，命令层撞哈希时警告疑似重复导入
    var transactionCount: Int = 0
    var importedAt: Date = Date.now
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(fileName: String, importedAt: Date) {
        self.fileName = fileName
        self.importedAt = importedAt
    }
}
