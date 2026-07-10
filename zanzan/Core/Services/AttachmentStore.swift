import Foundation
import SwiftData

/// 附件文件存取层（设计文档 5.4 attachmentFileNames）。
/// 文件落 rootDirectory（默认 Documents/Attachments/），库里只存文件名引用；
/// 软删流水的附件保留（撤销需要），孤儿文件由 cleanOrphans 维护命令清理。
struct AttachmentStore {
    let context: ModelContext
    let rootDirectory: URL

    /// rootDirectory 可注入（测试传临时目录），默认 Documents/Attachments/
    init(context: ModelContext, rootDirectory: URL? = nil) {
        self.context = context
        self.rootDirectory = rootDirectory
            ?? URL.documentsDirectory.appending(path: "Attachments", directoryHint: .isDirectory)
    }

    /// 存附件：写文件（UUID 文件名）并把文件名追加到流水 attachmentFileNames，返回文件名
    @discardableResult
    func save(data: Data, for transactionUUID: UUID) throws -> String {
        let tx = try fetchActiveTransaction(transactionUUID)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let fileName = UUID().uuidString
        try data.write(to: fileURL(for: fileName), options: .atomic)
        tx.attachmentFileNames.append(fileName)
        tx.updatedAt = .now
        try context.save()
        return fileName
    }

    /// 读附件内容；文件不存在明确抛错
    func load(_ fileName: String) throws -> Data {
        let url = try validatedFileURL(for: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AttachmentStoreError.attachmentNotFound
        }
        return try Data(contentsOf: url)
    }

    /// 删附件：摘掉流水字段引用并删除文件（文件已缺失时只摘引用，保证幂等）
    func remove(_ fileName: String, from transactionUUID: UUID) throws {
        let tx = try fetchActiveTransaction(transactionUUID)
        guard tx.attachmentFileNames.contains(fileName) else {
            throw AttachmentStoreError.attachmentNotFound
        }
        let url = try validatedFileURL(for: fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        // 不变式：不可变风格生成新数组回写，避免半途失败留下不一致引用
        tx.attachmentFileNames = tx.attachmentFileNames.filter { $0 != fileName }
        tx.updatedAt = .now
        try context.save()
    }

    /// 孤儿清理维护命令：目录里没有任何流水（含软删，软删可恢复）引用的文件删除，返回清理数量
    func cleanOrphans() throws -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rootDirectory.path) else { return 0 }
        let transactions = try context.fetch(FetchDescriptor<Transaction>())
        let referenced = Set(transactions.flatMap(\.attachmentFileNames))
        let files = try fm.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil)
        var removedCount = 0
        for file in files where !referenced.contains(file.lastPathComponent) {
            try fm.removeItem(at: file)
            removedCount += 1
        }
        return removedCount
    }

    // MARK: - 私有

    /// 活跃流水：软删流水禁止增删附件（附件本体保留待恢复）
    private func fetchActiveTransaction(_ uuid: UUID) throws -> Transaction {
        let descriptor = FetchDescriptor<Transaction>(predicate: #Predicate { $0.uuid == uuid })
        guard let tx = try context.fetch(descriptor).first else {
            throw AttachmentStoreError.transactionNotFound
        }
        guard !tx.isSoftDeleted else { throw AttachmentStoreError.transactionDeleted }
        return tx
    }

    /// 拒绝含路径分隔符的文件名，防目录穿越
    private func validatedFileURL(for fileName: String) throws -> URL {
        guard !fileName.isEmpty, !fileName.contains("/"), !fileName.contains("..") else {
            throw AttachmentStoreError.invalidFileName
        }
        return fileURL(for: fileName)
    }

    private func fileURL(for fileName: String) -> URL {
        rootDirectory.appending(path: fileName)
    }
}

enum AttachmentStoreError: LocalizedError {
    case transactionNotFound
    case transactionDeleted
    case attachmentNotFound
    case invalidFileName

    var errorDescription: String? {
        switch self {
        case .transactionNotFound: String(localized: "流水不存在")
        case .transactionDeleted: String(localized: "流水已删除，无法操作附件")
        case .attachmentNotFound: String(localized: "附件不存在或已被删除")
        case .invalidFileName: String(localized: "附件文件名非法")
        }
    }
}
