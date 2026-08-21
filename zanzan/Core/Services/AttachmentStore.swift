import Foundation
import SwiftData

/// 附件文件存取层（设计文档 5.4 attachmentFileNames）。
/// 文件落 rootDirectory（默认 Documents/Attachments/），库里只存文件名引用；
/// 软删流水的附件保留（撤销需要），孤儿文件由 cleanOrphans 维护命令清理。
struct AttachmentStore {
    nonisolated static let maximumAttachmentCount = 10_000
    nonisolated static let maximumAttachmentByteCount = 128 * 1_024 * 1_024
    nonisolated static let maximumTotalAttachmentByteCount = 256 * 1_024 * 1_024

    static let defaultRootDirectory = URL.documentsDirectory
        .appending(path: "Attachments", directoryHint: .isDirectory)

    let context: ModelContext
    let rootDirectory: URL

    /// rootDirectory 可注入（测试传临时目录），默认 Documents/Attachments/
    init(context: ModelContext, rootDirectory: URL? = nil) {
        self.context = context
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory
    }

    /// 存附件：写文件（UUID 文件名）并把文件名追加到流水 attachmentFileNames，返回文件名
    @discardableResult
    func save(data: Data, for transactionUUID: UUID) throws -> String {
        try saveAll(data: [data], for: transactionUUID)[0]
    }

    /// 批量存附件：全部文件写完后只提交一次引用；任一写入或数据库提交失败，
    /// 回滚上下文并删除本批已写文件，不留下半批引用或可预见的孤儿文件。
    @discardableResult
    func saveAll(data: [Data], for transactionUUID: UUID) throws -> [String] {
        let transaction = try fetchActiveTransaction(transactionUUID)
        return try saveAll(data: data, for: transaction)
    }

    /// 组合命令专用重载：允许尚未保存、但已插入当前 context 的流水参与最终一次提交。
    @discardableResult
    func saveAll(data: [Data], for transaction: Transaction) throws -> [String] {
        guard !transaction.isSoftDeleted else {
            throw AttachmentStoreError.transactionDeleted
        }
        guard !data.isEmpty else { return [] }
        try validateBackupCapacity(adding: data, to: transaction)

        var writtenURLs: [URL] = []
        do {
            try FileManager.default.createDirectory(
                at: rootDirectory,
                withIntermediateDirectories: true
            )
            var fileNames: [String] = []
            for bytes in data {
                let fileName = UUID().uuidString
                let url = fileURL(for: fileName)
                try bytes.write(to: url, options: .atomic)
                fileNames.append(fileName)
                writtenURLs.append(url)
            }
            transaction.attachmentFileNames.append(contentsOf: fileNames)
            transaction.updatedAt = .now
            try context.zanzanSave()
            return fileNames
        } catch {
            context.rollback()
            for url in writtenURLs {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }

    /// 读附件内容；文件不存在明确抛错
    func load(_ fileName: String) throws -> Data {
        let url = try validatedFileURL(for: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AttachmentStoreError.attachmentNotFound
        }
        return try Data(contentsOf: url)
    }

    /// 删附件：先提交摘引用，再删除文件。数据库保存失败时字节仍在；
    /// 文件删除失败最多留下可由 cleanOrphans 清理的孤儿，不会留下悬空引用。
    func remove(_ fileName: String, from transactionUUID: UUID) throws {
        let tx = try fetchActiveTransaction(transactionUUID)
        guard tx.attachmentFileNames.contains(fileName) else {
            throw AttachmentStoreError.attachmentNotFound
        }
        let url = try validatedFileURL(for: fileName)
        tx.attachmentFileNames = tx.attachmentFileNames.filter { $0 != fileName }
        tx.updatedAt = .now
        do {
            try context.zanzanSave()
        } catch {
            context.rollback()
            throw error
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 孤儿清理维护命令：目录里没有任何流水（含软删，软删可恢复）引用的文件删除，返回清理数量
    func cleanOrphans() throws -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rootDirectory.path) else { return 0 }
        let transactions = try context.fetch(FetchDescriptor<Transaction>())
        let referenced = Set(transactions.flatMap(\.attachmentFileNames))
        let files = try fm.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        var removedCount = 0
        for file in files {
            let fileName = file.lastPathComponent
            guard Self.isCanonicalAttachmentFileName(fileName),
                  try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                  !referenced.contains(fileName) else {
                continue
            }
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
        try Self.validateFileName(fileName)
        return fileURL(for: fileName)
    }

    nonisolated static func validateFileName(_ fileName: String) throws {
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              !fileName.hasPrefix(".zanzan-"),
              !fileName.contains("/"),
              !fileName.contains("\\") else {
            throw AttachmentStoreError.invalidFileName
        }
    }

    nonisolated static func isCanonicalAttachmentFileName(_ fileName: String) -> Bool {
        UUID(uuidString: fileName)?.uuidString == fileName
    }

    /// 正常写路径不能产生完整备份无法承载的数据库。
    /// ponytail: 每次附件写入扫描现有引用；达到万级附件且性能可测变差时再持久化容量索引。
    private func validateBackupCapacity(
        adding data: [Data],
        to transaction: Transaction
    ) throws {
        let transactions = try context.fetch(FetchDescriptor<Transaction>())
        var referenced = transactions.flatMap(\.attachmentFileNames)
        if !transactions.contains(where: { $0 === transaction }) {
            referenced.append(contentsOf: transaction.attachmentFileNames)
        }
        guard referenced.count <= Self.maximumAttachmentCount,
              data.count <= Self.maximumAttachmentCount - referenced.count else {
            throw AttachmentStoreError.backupCapacityExceeded
        }

        var totalByteCount = 0
        for fileName in referenced {
            try Self.validateFileName(fileName)
            guard Self.isCanonicalAttachmentFileName(fileName) else {
                throw AttachmentStoreError.invalidFileName
            }
            let values = try fileURL(for: fileName).resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )
            guard values.isRegularFile == true, let fileSize = values.fileSize else {
                throw AttachmentStoreError.attachmentNotFound
            }
            totalByteCount = try addingByteCount(fileSize, to: totalByteCount)
        }
        for bytes in data {
            totalByteCount = try addingByteCount(bytes.count, to: totalByteCount)
        }
    }

    private func addingByteCount(_ byteCount: Int, to total: Int) throws -> Int {
        let (newTotal, overflow) = total.addingReportingOverflow(byteCount)
        guard byteCount <= Self.maximumAttachmentByteCount,
              !overflow,
              newTotal <= Self.maximumTotalAttachmentByteCount else {
            throw AttachmentStoreError.backupCapacityExceeded
        }
        return newTotal
    }

    private func fileURL(for fileName: String) -> URL {
        rootDirectory.appending(path: fileName)
    }
}

nonisolated enum AttachmentStoreError: LocalizedError {
    case transactionNotFound
    case transactionDeleted
    case attachmentNotFound
    case invalidFileName
    case backupCapacityExceeded

    var errorDescription: String? {
        switch self {
        case .transactionNotFound: ZanzanLocalization.string( "流水不存在")
        case .transactionDeleted: ZanzanLocalization.string( "流水已删除，无法操作附件")
        case .attachmentNotFound: ZanzanLocalization.string( "附件不存在或已被删除")
        case .invalidFileName: ZanzanLocalization.string( "附件文件名非法")
        case .backupCapacityExceeded:
            ZanzanLocalization.string("附件数量或容量超过完整备份上限")
        }
    }
}
