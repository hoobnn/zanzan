import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct AttachmentStoreTests {
    /// 内存容器 + 独立临时目录的公共夹具
    private struct Fixture {
        let context: ModelContext
        let store: AttachmentStore
        let tempDirectory: URL
        let transaction: Transaction

        /// 测试结束清理临时目录
        func tearDown() {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    private func makeFixture() throws -> Fixture {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let ledger = try LedgerService(context: context).createLedger(LedgerDraft(name: "日常"))
        let cash = Account(name: "现金", kind: .fund)
        let dining = Category(name: "餐饮", kind: .expense, sortOrder: 0)
        context.insert(cash)
        context.insert(dining)
        try context.save()
        var draft = TransactionDraft()
        draft.kind = .expense
        draft.amountString = "25.50"
        draft.accountUUID = cash.uuid
        draft.categoryUUID = dining.uuid
        let tx = try TransactionService(context: context).recordTransaction(draft, ledgerID: ledger.uuid)
        let tempDirectory = FileManager.default.temporaryDirectory
            .appending(path: "AttachmentStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = AttachmentStore(context: context, rootDirectory: tempDirectory)
        return Fixture(context: context, store: store, tempDirectory: tempDirectory, transaction: tx)
    }

    @Test func 存取删闭环() throws {
        let f = try makeFixture()
        defer { f.tearDown() }
        let data = Data("票据照片".utf8)

        let fileName = try f.store.save(data: data, for: f.transaction.uuid)
        #expect(f.transaction.attachmentFileNames == [fileName])
        #expect(try f.store.load(fileName) == data)

        try f.store.remove(fileName, from: f.transaction.uuid)
        #expect(f.transaction.attachmentFileNames.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.tempDirectory.appending(path: fileName).path))
    }

    @Test func load不存在的附件抛错() throws {
        let f = try makeFixture()
        defer { f.tearDown() }
        #expect(throws: AttachmentStoreError.self) {
            _ = try f.store.load(UUID().uuidString)
        }
    }

    @Test func 摘除未引用的附件抛错() throws {
        let f = try makeFixture()
        defer { f.tearDown() }
        #expect(throws: AttachmentStoreError.self) {
            try f.store.remove(UUID().uuidString, from: f.transaction.uuid)
        }
    }

    @Test func 流水不存在时存附件抛错() throws {
        let f = try makeFixture()
        defer { f.tearDown() }
        #expect(throws: AttachmentStoreError.self) {
            _ = try f.store.save(data: Data("x".utf8), for: UUID())
        }
    }

    @Test func 软删流水禁止增删附件() throws {
        let f = try makeFixture()
        defer { f.tearDown() }
        let fileName = try f.store.save(data: Data("票据".utf8), for: f.transaction.uuid)
        try TransactionService(context: f.context).softDeleteTransaction(uuid: f.transaction.uuid)

        #expect(throws: AttachmentStoreError.self) {
            _ = try f.store.save(data: Data("再存".utf8), for: f.transaction.uuid)
        }
        #expect(throws: AttachmentStoreError.self) {
            try f.store.remove(fileName, from: f.transaction.uuid)
        }
        // 软删不影响读取（撤销恢复后仍可见）
        #expect(try f.store.load(fileName) == Data("票据".utf8))
    }

    @Test func 单个附件超过完整备份上限时零写入() throws {
        let f = try makeFixture()
        defer { f.tearDown() }
        let oversized = Data(count: AttachmentStore.maximumAttachmentByteCount + 1)

        #expect(throws: AttachmentStoreError.backupCapacityExceeded) {
            _ = try f.store.save(data: oversized, for: f.transaction.uuid)
        }

        #expect(f.transaction.attachmentFileNames.isEmpty)
        if FileManager.default.fileExists(atPath: f.tempDirectory.path) {
            #expect(
                try FileManager.default.contentsOfDirectory(
                    at: f.tempDirectory,
                    includingPropertiesForKeys: nil
                ).isEmpty
            )
        }
    }

    @Test func 既有附件达到总容量上限后新增失败且原文件不变() throws {
        let f = try makeFixture()
        defer { f.tearDown() }
        try FileManager.default.createDirectory(
            at: f.tempDirectory,
            withIntermediateDirectories: true
        )
        let fileNames = [UUID().uuidString, UUID().uuidString]
        for fileName in fileNames {
            let url = f.tempDirectory.appending(path: fileName)
            #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(AttachmentStore.maximumAttachmentByteCount))
            try handle.close()
        }
        f.transaction.attachmentFileNames = fileNames
        try f.context.save()

        #expect(throws: AttachmentStoreError.backupCapacityExceeded) {
            _ = try f.store.save(data: Data([0x01]), for: f.transaction.uuid)
        }

        #expect(f.transaction.attachmentFileNames == fileNames)
        #expect(
            try FileManager.default.contentsOfDirectory(
                at: f.tempDirectory,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent).sorted() == fileNames.sorted()
        )
    }

    @Test func 既有附件达到数量上限后新增失败且不访问缺失文件() throws {
        let f = try makeFixture()
        defer { f.tearDown() }
        let fileNames = (0..<AttachmentStore.maximumAttachmentCount).map { _ in
            UUID().uuidString
        }
        f.transaction.attachmentFileNames = fileNames
        try f.context.save()

        #expect(throws: AttachmentStoreError.backupCapacityExceeded) {
            _ = try f.store.save(data: Data([0x01]), for: f.transaction.uuid)
        }

        #expect(f.transaction.attachmentFileNames == fileNames)
        #expect(!FileManager.default.fileExists(atPath: f.tempDirectory.path))
    }

    @Test func 孤儿清理保留活跃与软删引用() throws {
        let f = try makeFixture()
        defer { f.tearDown() }
        // 活跃流水引用一个附件
        let activeFile = try f.store.save(data: Data("活跃".utf8), for: f.transaction.uuid)
        // 软删流水引用一个附件（软删可恢复，须保留）
        var draft = TransactionDraft()
        draft.kind = .expense
        draft.amountString = "10"
        draft.accountUUID = f.transaction.account!.uuid
        draft.categoryUUID = f.transaction.category!.uuid
        let deletedTx = try TransactionService(context: f.context)
            .recordTransaction(draft, ledgerID: f.transaction.ledgerID!)
        let deletedFile = try f.store.save(data: Data("软删".utf8), for: deletedTx.uuid)
        try TransactionService(context: f.context).softDeleteTransaction(uuid: deletedTx.uuid)
        // 目录里放一个无人引用的孤儿文件
        let orphanURL = f.tempDirectory.appending(path: UUID().uuidString)
        try Data("孤儿".utf8).write(to: orphanURL)

        let removedCount = try f.store.cleanOrphans()

        #expect(removedCount == 1)
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
        #expect(try f.store.load(activeFile) == Data("活跃".utf8))
        #expect(try f.store.load(deletedFile) == Data("软删".utf8))
    }

    @Test func 孤儿清理在目录不存在时返回零() throws {
        let f = try makeFixture()
        defer { f.tearDown() }
        // 未存过任何附件，目录尚未创建
        #expect(try f.store.cleanOrphans() == 0)
    }
}
