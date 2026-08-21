import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct FullBackupServiceTests {
    private struct BytePreservingManifestEnvelope: Codable {
        let contentData: Data
        let checksum: String
    }

    private struct Fixture {
        let context: ModelContext
        let attachmentDirectory: URL
        let safetyBackupURL: URL
        let temporaryDirectory: URL

        func tearDown() {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    private func makeFixture() throws -> Fixture {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "FullBackupServiceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        return Fixture(
            context: ModelContext(try AppModelContainer.make(inMemory: true)),
            attachmentDirectory: temporaryDirectory
                .appending(path: "Attachments", directoryHint: .isDirectory),
            safetyBackupURL: temporaryDirectory
                .appending(path: "PreRestore.zanzanbackup", directoryHint: .isDirectory),
            temporaryDirectory: temporaryDirectory
        )
    }

    @Test func 全量备份恢复精确替换并保留附件与关系() throws {
        let source = try makeFixture()
        defer { source.tearDown() }

        let ledger = Ledger(name: "旅行账本")
        ledger.isDefault = true
        let account = Account(name: "美元现金", kind: .fund)
        account.currencyCode = "USD"
        let category = Category(name: "交通", kind: .expense, sortOrder: 3)
        category.ledgerID = ledger.uuid
        let tag = Tag(name: "出差")
        tag.ledgerID = ledger.uuid
        let transaction = Transaction(
            kind: .expense,
            amountMinorUnits: 12_345,
            occurredAt: Date(timeIntervalSince1970: 1_735_689_600),
            ledgerID: ledger.uuid
        )
        transaction.account = account
        transaction.category = category
        transaction.tags = [tag]
        transaction.currencyCode = "USD"
        transaction.fxRateToBase = Decimal(string: "7.2345")
        transaction.note = "机场快线"
        source.context.insert(ledger)
        source.context.insert(account)
        source.context.insert(category)
        source.context.insert(tag)
        source.context.insert(transaction)
        try source.context.zanzanSave()

        let attachmentBytes = Data("receipt-image-bytes".utf8)
        let attachmentFileName = try AttachmentStore(
            context: source.context,
            rootDirectory: source.attachmentDirectory
        ).save(data: attachmentBytes, for: transaction.uuid)

        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let archive = try FullBackupService(
            context: source.context,
            attachmentRootDirectory: source.attachmentDirectory,
            safetyBackupURL: source.safetyBackupURL
        ).export(createdAt: createdAt)
        let archiveURL = source.temporaryDirectory
            .appending(path: "RoundTrip.zanzanbackup", directoryHint: .isDirectory)
        try archive.write(to: archiveURL)
        let diskArchive = try ZanzanBackupPackage.read(from: archiveURL)

        let target = try makeFixture()
        defer { target.tearDown() }
        let sentinel = Ledger(name: "目标库残留")
        sentinel.isDefault = true
        target.context.insert(sentinel)
        try target.context.zanzanSave()

        let targetService = FullBackupService(
            context: target.context,
            attachmentRootDirectory: target.attachmentDirectory,
            safetyBackupURL: target.safetyBackupURL
        )
        let summary = try targetService.restore(diskArchive)

        let restoredLedgers = try target.context.fetch(FetchDescriptor<Ledger>())
        let restoredAccounts = try target.context.fetch(FetchDescriptor<Account>())
        let restoredCategories = try target.context.fetch(FetchDescriptor<Category>())
        let restoredTags = try target.context.fetch(FetchDescriptor<Tag>())
        let restoredTransactions = try target.context.fetch(FetchDescriptor<Transaction>())
        let restored = try #require(restoredTransactions.first)

        #expect(restoredLedgers.map(\.uuid) == [ledger.uuid])
        #expect(restoredAccounts.map(\.uuid) == [account.uuid])
        #expect(restoredCategories.map(\.uuid) == [category.uuid])
        #expect(restoredTags.map(\.uuid) == [tag.uuid])
        #expect(restoredTransactions.map(\.uuid) == [transaction.uuid])
        #expect(restored.account?.uuid == account.uuid)
        #expect(restored.category?.uuid == category.uuid)
        #expect(restored.tags?.map(\.uuid) == [tag.uuid])
        #expect(restored.amountMinorUnits == 12_345)
        #expect(restored.fxRateToBase == Decimal(string: "7.2345"))
        #expect(restored.attachmentFileNames == [attachmentFileName])
        #expect(
            try AttachmentStore(
                context: target.context,
                rootDirectory: target.attachmentDirectory
            ).load(attachmentFileName) == attachmentBytes
        )
        #expect(summary.createdAt == createdAt)
        #expect(summary.attachmentCount == 1)
        #expect(FileManager.default.fileExists(atPath: target.safetyBackupURL.path))

        let loadedSafetyBackup = try targetService.loadSafetyBackup()
        let safetyBackup = try #require(loadedSafetyBackup)
        let rollbackTarget = try makeFixture()
        defer { rollbackTarget.tearDown() }
        try FullBackupService(
            context: rollbackTarget.context,
            attachmentRootDirectory: rollbackTarget.attachmentDirectory,
            safetyBackupURL: rollbackTarget.safetyBackupURL
        ).restore(safetyBackup, createsSafetyBackup: false)
        #expect(
            try rollbackTarget.context.fetch(FetchDescriptor<Ledger>()).map(\.uuid)
                == [sentinel.uuid]
        )

        let countsBeforeSeed = (
            restoredLedgers.count,
            restoredAccounts.count,
            restoredCategories.count
        )
        try DefaultDataSeeder(context: target.context).seedIfNeeded()
        #expect(try target.context.fetchCount(FetchDescriptor<Ledger>()) == countsBeforeSeed.0)
        #expect(try target.context.fetchCount(FetchDescriptor<Account>()) == countsBeforeSeed.1)
        #expect(try target.context.fetchCount(FetchDescriptor<Category>()) == countsBeforeSeed.2)
    }

    @Test func 未知来源类型与原始sourceID可备份恢复不被归一化() throws {
        let source = try makeFixture()
        defer { source.tearDown() }
        let ledger = Ledger(name: "未来账本")
        ledger.isDefault = true
        let account = Account(name: "未来账户", kind: .fund)
        let category = Category(name: "未来分类", kind: .expense, sortOrder: 0)
        let transaction = Transaction(
            kind: .expense,
            amountMinorUnits: 100,
            occurredAt: .now,
            ledgerID: ledger.uuid
        )
        let futureSourceID = UUID()
        transaction.account = account
        transaction.category = category
        transaction.kindRawValue = "futureTransactionKind"
        transaction.sourceKindRawValue = "futureSourceKind"
        transaction.sourceID = futureSourceID
        source.context.insert(ledger)
        source.context.insert(account)
        source.context.insert(category)
        source.context.insert(transaction)
        try source.context.save()

        let archive = try FullBackupService(
            context: source.context,
            attachmentRootDirectory: source.attachmentDirectory,
            safetyBackupURL: source.safetyBackupURL
        ).export()

        let target = try makeFixture()
        defer { target.tearDown() }
        try FullBackupService(
            context: target.context,
            attachmentRootDirectory: target.attachmentDirectory,
            safetyBackupURL: target.safetyBackupURL
        ).restore(archive, createsSafetyBackup: false)

        let restored = try #require(
            try target.context.fetch(FetchDescriptor<Transaction>()).first
        )
        #expect(restored.kindRawValue == "futureTransactionKind")
        #expect(restored.kind == nil)
        #expect(restored.sourceKindRawValue == "futureSourceKind")
        #expect(restored.sourceKind == nil)
        #expect(restored.sourceID == futureSourceID)
    }

    @Test func 高版本目标库拒绝恢复且数据库与附件零变更() throws {
        let source = try makeFixture()
        defer { source.tearDown() }
        let sourceLedger = Ledger(name: "低版本备份")
        sourceLedger.isDefault = true
        source.context.insert(sourceLedger)
        try source.context.zanzanSave()
        let archive = try FullBackupService(
            context: source.context,
            attachmentRootDirectory: source.attachmentDirectory,
            safetyBackupURL: source.safetyBackupURL
        ).export()

        let target = try makeFixture()
        defer { target.tearDown() }
        let sentinel = Ledger(name: "高版本目标数据")
        sentinel.isDefault = true
        target.context.insert(sentinel)
        target.context.insert(AppMeta(key: CompatibilityWriteGate.key, value: "99.0.0"))
        try target.context.save()
        try FileManager.default.createDirectory(
            at: target.attachmentDirectory,
            withIntermediateDirectories: true
        )
        let existingAttachment = target.attachmentDirectory.appending(path: "existing-file")
        try Data("must-survive".utf8).write(to: existingAttachment)

        #expect(
            throws: CompatibilityWriteGateError.requiresNewerApp(required: "99.0.0")
        ) {
            try FullBackupService(
                context: target.context,
                attachmentRootDirectory: target.attachmentDirectory,
                safetyBackupURL: target.safetyBackupURL
            ).restore(archive, createsSafetyBackup: false)
        }

        let ledgers = try target.context.fetch(FetchDescriptor<Ledger>())
        #expect(ledgers.map(\.uuid) == [sentinel.uuid])
        #expect(try Data(contentsOf: existingAttachment) == Data("must-survive".utf8))
    }

    @Test func 分类循环或超过两级时拒绝生成不可恢复备份() throws {
        let source = try makeFixture()
        defer { source.tearDown() }
        let ledger = Ledger(name: "异常分类账本")
        ledger.isDefault = true
        let first = Category(name: "一级", kind: .expense, sortOrder: 0)
        let second = Category(name: "二级", kind: .expense, sortOrder: 0)
        first.parentID = second.uuid
        second.parentID = first.uuid
        source.context.insert(ledger)
        source.context.insert(first)
        source.context.insert(second)
        try source.context.save()

        #expect(
            throws: ZanzanBackupPayloadError.invalidHierarchy(entity: "Category")
        ) {
            _ = try FullBackupService(
                context: source.context,
                attachmentRootDirectory: source.attachmentDirectory,
                safetyBackupURL: source.safetyBackupURL
            ).export()
        }
    }

    @Test func 子分类方向或账本范围与父分类不一致时拒绝备份() throws {
        let source = try makeFixture()
        defer { source.tearDown() }
        let ledger = Ledger(name: "分类账本")
        let parent = Category(name: "支出父类", kind: .expense, sortOrder: 0)
        parent.ledgerID = ledger.uuid
        let child = Category(name: "错误收入子类", kind: .income, sortOrder: 0)
        child.ledgerID = ledger.uuid
        child.parentID = parent.uuid
        source.context.insert(ledger)
        source.context.insert(parent)
        source.context.insert(child)
        try source.context.save()

        #expect(
            throws: ZanzanBackupPayloadError.invalidHierarchy(entity: "Category")
        ) {
            _ = try FullBackupService(
                context: source.context,
                attachmentRootDirectory: source.attachmentDirectory,
                safetyBackupURL: source.safetyBackupURL
            ).export()
        }
    }

    @Test func 已知流水与周期模板缺少必填关系时拒绝备份() throws {
        let transactionFixture = try makeFixture()
        defer { transactionFixture.tearDown() }
        let ledger = Ledger(name: "流水账本")
        let account = Account(name: "现金", kind: .fund)
        let transaction = Transaction(
            kind: .expense,
            amountMinorUnits: 100,
            occurredAt: .now,
            ledgerID: ledger.uuid
        )
        transaction.account = account
        transactionFixture.context.insert(ledger)
        transactionFixture.context.insert(account)
        transactionFixture.context.insert(transaction)
        try transactionFixture.context.save()

        #expect(
            throws: ZanzanBackupPayloadError.brokenReference(
                entity: "Transaction",
                field: "categoryID"
            )
        ) {
            _ = try FullBackupService(
                context: transactionFixture.context,
                attachmentRootDirectory: transactionFixture.attachmentDirectory,
                safetyBackupURL: transactionFixture.safetyBackupURL
            ).export()
        }

        let sourceFixture = try makeFixture()
        defer { sourceFixture.tearDown() }
        let sourceLedger = Ledger(name: "导入账本")
        let sourceAccount = Account(name: "银行卡", kind: .fund)
        let sourceCategory = Category(name: "餐饮", kind: .expense, sortOrder: 0)
        let imported = Transaction(
            kind: .expense,
            amountMinorUnits: 200,
            occurredAt: .now,
            ledgerID: sourceLedger.uuid
        )
        imported.account = sourceAccount
        imported.category = sourceCategory
        imported.sourceKindRawValue = TransactionSourceKind.csvImport.rawValue
        sourceFixture.context.insert(sourceLedger)
        sourceFixture.context.insert(sourceAccount)
        sourceFixture.context.insert(sourceCategory)
        sourceFixture.context.insert(imported)
        try sourceFixture.context.save()

        #expect(
            throws: ZanzanBackupPayloadError.brokenReference(
                entity: "Transaction",
                field: "sourceID"
            )
        ) {
            _ = try FullBackupService(
                context: sourceFixture.context,
                attachmentRootDirectory: sourceFixture.attachmentDirectory,
                safetyBackupURL: sourceFixture.safetyBackupURL
            ).export()
        }

        let recurringFixture = try makeFixture()
        defer { recurringFixture.tearDown() }
        let recurringLedger = Ledger(name: "周期账本")
        let recurringAccount = Account(name: "工资卡", kind: .fund)
        let rule = RecurringRule(
            name: "工资",
            frequency: .monthly,
            startAt: .now,
            nextRunAt: .now,
            templateKind: .income,
            templateAmountMinorUnits: 10_000
        )
        rule.templateLedgerID = recurringLedger.uuid
        rule.templateAccountID = recurringAccount.uuid
        recurringFixture.context.insert(recurringLedger)
        recurringFixture.context.insert(recurringAccount)
        recurringFixture.context.insert(rule)
        try recurringFixture.context.save()

        #expect(
            throws: ZanzanBackupPayloadError.brokenReference(
                entity: "RecurringRule",
                field: "templateCategoryID"
            )
        ) {
            _ = try FullBackupService(
                context: recurringFixture.context,
                attachmentRootDirectory: recurringFixture.attachmentDirectory,
                safetyBackupURL: recurringFixture.safetyBackupURL
            ).export()
        }
    }

    @Test func 清单按原始内容字节验签而不依赖重编码() throws {
        let source = try makeFixture()
        defer { source.tearDown() }
        let ledger = Ledger(name: "历史备份账本")
        source.context.insert(ledger)
        try source.context.save()

        let content = ZanzanBackupManifestContent(
            formatVersion: FullBackupService.currentFormatVersion,
            schemaVersion: CompatibilityWriteGate.currentVersionString,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            payload: try ZanzanBackupPayload(context: source.context),
            attachments: []
        )
        let contentEncoder = JSONEncoder()
        contentEncoder.dateEncodingStrategy = .millisecondsSince1970
        contentEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let contentData = try contentEncoder.encode(content)
        let checksum = SHA256.hash(data: contentData)
            .map { String(format: "%02x", $0) }
            .joined()
        let staleChecksumManifest = try JSONEncoder().encode(
            BytePreservingManifestEnvelope(
                contentData: contentData + Data("\n".utf8),
                checksum: checksum
            )
        )
        let manifest = try JSONEncoder().encode(
            BytePreservingManifestEnvelope(
                contentData: contentData,
                checksum: checksum
            )
        )

        let untouched = try makeFixture()
        defer { untouched.tearDown() }
        let sentinel = Ledger(name: "不能被修改")
        untouched.context.insert(sentinel)
        try untouched.context.save()
        #expect(throws: FullBackupError.manifestIntegrityFailed) {
            try FullBackupService(
                context: untouched.context,
                attachmentRootDirectory: untouched.attachmentDirectory,
                safetyBackupURL: untouched.safetyBackupURL
            ).restore(
                ZanzanBackupPackage(
                    manifest: staleChecksumManifest,
                    attachments: [:]
                ),
                createsSafetyBackup: false
            )
        }
        #expect(
            try untouched.context.fetch(FetchDescriptor<Ledger>()).map(\.uuid)
                == [sentinel.uuid]
        )

        let target = try makeFixture()
        defer { target.tearDown() }
        try FullBackupService(
            context: target.context,
            attachmentRootDirectory: target.attachmentDirectory,
            safetyBackupURL: target.safetyBackupURL
        ).restore(
            ZanzanBackupPackage(manifest: manifest, attachments: [:]),
            createsSafetyBackup: false
        )

        #expect(
            try target.context.fetch(FetchDescriptor<Ledger>()).map(\.uuid) == [ledger.uuid]
        )
    }

    @Test func 超出附件数量边界时在修改目标前拒绝恢复() throws {
        let source = try makeFixture()
        defer { source.tearDown() }
        let ledger = Ledger(name: "来源账本")
        source.context.insert(ledger)
        try source.context.save()
        let archive = try FullBackupService(
            context: source.context,
            attachmentRootDirectory: source.attachmentDirectory,
            safetyBackupURL: source.safetyBackupURL
        ).export()
        let excessiveAttachments = Dictionary(
            uniqueKeysWithValues: (0...ZanzanBackupPackage.maximumAttachmentCount).map {
                ("00000000-0000-0000-0000-\(String(format: "%012d", $0))", Data())
            }
        )

        let target = try makeFixture()
        defer { target.tearDown() }
        let sentinel = Ledger(name: "不能被修改")
        target.context.insert(sentinel)
        try target.context.save()

        #expect(throws: FullBackupError.packageTooLarge) {
            try FullBackupService(
                context: target.context,
                attachmentRootDirectory: target.attachmentDirectory,
                safetyBackupURL: target.safetyBackupURL
            ).restore(
                ZanzanBackupPackage(
                    manifest: archive.manifest,
                    attachments: excessiveAttachments
                ),
                createsSafetyBackup: false
            )
        }
        #expect(
            try target.context.fetch(FetchDescriptor<Ledger>()).map(\.uuid) == [sentinel.uuid]
        )
    }

    @Test func 附件字节被篡改时目标库和原附件保持不变() throws {
        let source = try makeFixture()
        defer { source.tearDown() }
        let ledger = Ledger(name: "来源账本")
        let account = Account(name: "现金", kind: .fund)
        let category = Category(name: "餐饮", kind: .expense, sortOrder: 0)
        let transaction = Transaction(
            kind: .expense,
            amountMinorUnits: 100,
            occurredAt: .now,
            ledgerID: ledger.uuid
        )
        transaction.account = account
        transaction.category = category
        source.context.insert(ledger)
        source.context.insert(account)
        source.context.insert(category)
        source.context.insert(transaction)
        try source.context.save()
        let fileName = try AttachmentStore(
            context: source.context,
            rootDirectory: source.attachmentDirectory
        ).save(data: Data("original".utf8), for: transaction.uuid)
        let archive = try FullBackupService(
            context: source.context,
            attachmentRootDirectory: source.attachmentDirectory,
            safetyBackupURL: source.safetyBackupURL
        ).export()
        var tamperedAttachments = archive.attachments
        tamperedAttachments[fileName] = Data("tampered".utf8)

        let target = try makeFixture()
        defer { target.tearDown() }
        let sentinel = Ledger(name: "不能被修改")
        target.context.insert(sentinel)
        try target.context.save()
        try FileManager.default.createDirectory(
            at: target.attachmentDirectory,
            withIntermediateDirectories: true
        )
        let existingFileName = UUID().uuidString
        let existingBytes = Data("target-attachment".utf8)
        let existingURL = target.attachmentDirectory.appending(path: existingFileName)
        try existingBytes.write(to: existingURL)

        #expect(throws: FullBackupError.attachmentIntegrityFailed(fileName)) {
            try FullBackupService(
                context: target.context,
                attachmentRootDirectory: target.attachmentDirectory,
                safetyBackupURL: target.safetyBackupURL
            ).restore(
                ZanzanBackupPackage(
                    manifest: archive.manifest,
                    attachments: tamperedAttachments
                )
            )
        }
        #expect(
            try target.context.fetch(FetchDescriptor<Ledger>()).map(\.uuid) == [sentinel.uuid]
        )
        #expect(try Data(contentsOf: existingURL) == existingBytes)
        #expect(!FileManager.default.fileExists(atPath: target.safetyBackupURL.path))
    }

    @Test func 恢复日志保留名不能伪装成流水附件() throws {
        let source = try makeFixture()
        defer { source.tearDown() }
        let ledger = Ledger(name: "附件账本")
        ledger.isDefault = true
        let account = Account(name: "现金", kind: .fund)
        let category = Category(name: "其他", kind: .expense, sortOrder: 0)
        let transaction = Transaction(
            kind: .expense,
            amountMinorUnits: 100,
            occurredAt: .now,
            ledgerID: ledger.uuid
        )
        transaction.account = account
        transaction.category = category
        transaction.attachmentFileNames = [".zanzan-restore-id"]
        source.context.insert(ledger)
        source.context.insert(account)
        source.context.insert(category)
        source.context.insert(transaction)
        try source.context.save()
        try FileManager.default.createDirectory(
            at: source.attachmentDirectory,
            withIntermediateDirectories: true
        )
        try Data("not-a-journal".utf8).write(
            to: source.attachmentDirectory.appending(path: ".zanzan-restore-id")
        )

        #expect(throws: AttachmentStoreError.invalidFileName) {
            _ = try FullBackupService(
                context: source.context,
                attachmentRootDirectory: source.attachmentDirectory,
                safetyBackupURL: source.safetyBackupURL
            ).export()
        }
    }

    @Test func 仅剩回滚目录时自动恢复旧附件() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let rollbackDirectory = fixture.attachmentDirectory
            .deletingLastPathComponent()
            .appending(
                path: ".\(fixture.attachmentDirectory.lastPathComponent).restore-rollback",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: rollbackDirectory,
            withIntermediateDirectories: true
        )
        let fileName = UUID().uuidString
        let bytes = Data("old-attachment".utf8)
        try bytes.write(to: rollbackDirectory.appending(path: fileName))

        try FullBackupService(
            context: fixture.context,
            attachmentRootDirectory: fixture.attachmentDirectory,
            safetyBackupURL: fixture.safetyBackupURL
        ).recoverInterruptedRestore()

        #expect(
            try Data(contentsOf: fixture.attachmentDirectory.appending(path: fileName)) == bytes
        )
        #expect(!FileManager.default.fileExists(atPath: rollbackDirectory.path))
    }

    @Test func 高版本库存在恢复残留时附件目录保持零变更() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        fixture.context.insert(
            AppMeta(key: CompatibilityWriteGate.key, value: "99.0.0")
        )
        try fixture.context.save()
        let rollbackDirectory = fixture.attachmentDirectory
            .deletingLastPathComponent()
            .appending(
                path: ".\(fixture.attachmentDirectory.lastPathComponent).restore-rollback",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: rollbackDirectory,
            withIntermediateDirectories: true
        )
        let fileName = UUID().uuidString
        let bytes = Data("must-not-move".utf8)
        let rollbackFile = rollbackDirectory.appending(path: fileName)
        try bytes.write(to: rollbackFile)

        #expect(
            throws: CompatibilityWriteGateError.requiresNewerApp(required: "99.0.0")
        ) {
            try FullBackupService(
                context: fixture.context,
                attachmentRootDirectory: fixture.attachmentDirectory,
                safetyBackupURL: fixture.safetyBackupURL
            ).recoverInterruptedRestore()
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.attachmentDirectory.path))
        #expect(try Data(contentsOf: rollbackFile) == bytes)
    }

    @Test func 无恢复日志的暂存目录会在启动收敛时清理() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let stagingDirectory = fixture.attachmentDirectory
            .deletingLastPathComponent()
            .appending(
                path: ".\(fixture.attachmentDirectory.lastPathComponent).restore-staging",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: fixture.attachmentDirectory,
            withIntermediateDirectories: true
        )
        let existingFile = fixture.attachmentDirectory.appending(path: UUID().uuidString)
        let existingBytes = Data("current".utf8)
        try existingBytes.write(to: existingFile)
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        try Data("orphan".utf8).write(
            to: stagingDirectory.appending(path: UUID().uuidString)
        )

        try FullBackupService(
            context: fixture.context,
            attachmentRootDirectory: fixture.attachmentDirectory,
            safetyBackupURL: fixture.safetyBackupURL
        ).recoverInterruptedRestore()

        #expect(!FileManager.default.fileExists(atPath: stagingDirectory.path))
        #expect(try Data(contentsOf: existingFile) == existingBytes)
    }

    @Test func 孤儿清理不会破坏待收敛的恢复日志() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let ledger = Ledger(name: "恢复账本")
        let account = Account(name: "现金", kind: .fund)
        let category = Category(name: "其他", kind: .expense, sortOrder: 0)
        let transaction = Transaction(
            kind: .expense,
            amountMinorUnits: 100,
            occurredAt: .now,
            ledgerID: ledger.uuid
        )
        let fileName = UUID().uuidString
        transaction.account = account
        transaction.category = category
        transaction.attachmentFileNames = [fileName]
        let restoreID = UUID().uuidString
        fixture.context.insert(ledger)
        fixture.context.insert(account)
        fixture.context.insert(category)
        fixture.context.insert(transaction)
        fixture.context.insert(
            AppMeta(key: FullBackupService.lastRestoreIDKey, value: restoreID)
        )
        try fixture.context.save()

        try FileManager.default.createDirectory(
            at: fixture.attachmentDirectory,
            withIntermediateDirectories: true
        )
        let attachmentBytes = Data("new-attachment".utf8)
        let attachmentURL = fixture.attachmentDirectory.appending(path: fileName)
        try attachmentBytes.write(to: attachmentURL)
        let markerURL = fixture.attachmentDirectory.appending(path: ".zanzan-restore-id")
        try Data(restoreID.utf8).write(to: markerURL)
        let rollbackDirectory = fixture.attachmentDirectory
            .deletingLastPathComponent()
            .appending(
                path: ".\(fixture.attachmentDirectory.lastPathComponent).restore-rollback",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: rollbackDirectory,
            withIntermediateDirectories: true
        )
        try Data("old-attachment".utf8).write(
            to: rollbackDirectory.appending(path: UUID().uuidString)
        )

        let removed = try AttachmentStore(
            context: fixture.context,
            rootDirectory: fixture.attachmentDirectory
        ).cleanOrphans()
        #expect(removed == 0)
        #expect(FileManager.default.fileExists(atPath: markerURL.path))

        try FullBackupService(
            context: fixture.context,
            attachmentRootDirectory: fixture.attachmentDirectory,
            safetyBackupURL: fixture.safetyBackupURL
        ).recoverInterruptedRestore()

        #expect(try Data(contentsOf: attachmentURL) == attachmentBytes)
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
        #expect(!FileManager.default.fileExists(atPath: rollbackDirectory.path))
    }

    @Test func 同一数据库按重叠UUID恢复时仍精确回到备份状态() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let ledger = Ledger(name: "原始账本")
        ledger.isDefault = true
        fixture.context.insert(ledger)
        try fixture.context.save()
        let service = FullBackupService(
            context: fixture.context,
            attachmentRootDirectory: fixture.attachmentDirectory,
            safetyBackupURL: fixture.safetyBackupURL
        )
        let archive = try service.export()

        ledger.name = "已被修改"
        fixture.context.insert(Ledger(name: "恢复时应删除"))
        try fixture.context.save()

        try service.restore(archive)

        let restored = try fixture.context.fetch(FetchDescriptor<Ledger>())
        #expect(restored.count == 1)
        #expect(restored.first?.uuid == ledger.uuid)
        #expect(restored.first?.name == "原始账本")
    }
}
