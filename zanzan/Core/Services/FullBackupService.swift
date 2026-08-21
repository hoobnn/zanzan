import CryptoKit
import Foundation
import SwiftData

struct ZanzanBackupAttachmentManifest: Codable, Equatable {
    let fileName: String
    let byteCount: Int
    let sha256: String
}

struct ZanzanBackupManifestContent: Codable {
    let formatVersion: Int
    let schemaVersion: String
    let createdAt: Date
    let payload: ZanzanBackupPayload
    let attachments: [ZanzanBackupAttachmentManifest]
}

private struct ZanzanBackupManifestEnvelope: Codable {
    let contentData: Data
    let checksum: String
}

nonisolated struct ZanzanBackupPackage {
    static let manifestFileName = "manifest.json"
    static let attachmentsDirectoryName = "Attachments"
    static let maximumManifestByteCount = 64 * 1_024 * 1_024
    static let maximumAttachmentCount = AttachmentStore.maximumAttachmentCount
    static let maximumAttachmentByteCount = AttachmentStore.maximumAttachmentByteCount
    static let maximumTotalAttachmentByteCount =
        AttachmentStore.maximumTotalAttachmentByteCount

    let manifest: Data
    let attachments: [String: Data]

    init(manifest: Data, attachments: [String: Data]) {
        self.manifest = manifest
        self.attachments = attachments
    }

    init(fileWrapper: FileWrapper) throws {
        guard fileWrapper.isDirectory,
              let children = fileWrapper.fileWrappers,
              Set(children.keys) == [Self.manifestFileName, Self.attachmentsDirectoryName],
              let manifestWrapper = children[Self.manifestFileName],
              manifestWrapper.isRegularFile else {
            throw FullBackupError.invalidPackage
        }
        guard try Self.reportedSize(of: manifestWrapper) <= Self.maximumManifestByteCount else {
            throw FullBackupError.packageTooLarge
        }
        guard let manifest = manifestWrapper.regularFileContents else {
            throw FullBackupError.invalidPackage
        }
        guard manifest.count <= Self.maximumManifestByteCount else {
            throw FullBackupError.packageTooLarge
        }
        guard let attachmentsWrapper = children[Self.attachmentsDirectoryName],
              attachmentsWrapper.isDirectory,
              let files = attachmentsWrapper.fileWrappers else {
            throw FullBackupError.invalidPackage
        }
        guard files.count <= Self.maximumAttachmentCount else {
            throw FullBackupError.packageTooLarge
        }
        var attachmentBytes: [String: Data] = [:]
        var reportedTotal = 0
        var actualTotal = 0
        for (fileName, wrapper) in files {
            try Self.validateAttachmentFileName(fileName)
            guard wrapper.isRegularFile else {
                throw FullBackupError.invalidPackage
            }
            let size = try Self.reportedSize(of: wrapper)
            let (newTotal, overflow) = reportedTotal.addingReportingOverflow(size)
            guard size <= Self.maximumAttachmentByteCount,
                  !overflow,
                  newTotal <= Self.maximumTotalAttachmentByteCount else {
                throw FullBackupError.packageTooLarge
            }
            guard let data = wrapper.regularFileContents else {
                throw FullBackupError.invalidPackage
            }
            actualTotal = try Self.addingAttachmentByteCount(data, to: actualTotal)
            guard attachmentBytes.updateValue(data, forKey: fileName) == nil else {
                throw FullBackupError.invalidPackage
            }
            reportedTotal = newTotal
        }
        self.init(manifest: manifest, attachments: attachmentBytes)
        try validateResourceLimits()
    }

    func fileWrapper() -> FileWrapper {
        let manifestWrapper = FileWrapper(regularFileWithContents: manifest)
        manifestWrapper.preferredFilename = Self.manifestFileName
        var attachmentWrappers: [String: FileWrapper] = [:]
        for (fileName, data) in attachments {
            let wrapper = FileWrapper(regularFileWithContents: data)
            wrapper.preferredFilename = fileName
            attachmentWrappers[fileName] = wrapper
        }
        let attachmentsWrapper = FileWrapper(directoryWithFileWrappers: attachmentWrappers)
        attachmentsWrapper.preferredFilename = Self.attachmentsDirectoryName
        return FileWrapper(
            directoryWithFileWrappers: [
                Self.manifestFileName: manifestWrapper,
                Self.attachmentsDirectoryName: attachmentsWrapper,
            ]
        )
    }

    static func read(from url: URL) throws -> Self {
        try Self(fileWrapper: FileWrapper(url: url, options: []))
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileWrapper().write(
            to: url,
            options: .atomic,
            originalContentsURL: FileManager.default.fileExists(atPath: url.path) ? url : nil
        )
    }

    func validateResourceLimits() throws {
        guard manifest.count <= Self.maximumManifestByteCount,
              attachments.count <= Self.maximumAttachmentCount else {
            throw FullBackupError.packageTooLarge
        }
        var total = 0
        for (fileName, data) in attachments {
            try Self.validateAttachmentFileName(fileName)
            total = try Self.addingAttachmentByteCount(data, to: total)
        }
    }

    static func validateAttachmentFileName(_ fileName: String) throws {
        try AttachmentStore.validateFileName(fileName)
        guard AttachmentStore.isCanonicalAttachmentFileName(fileName) else {
            throw FullBackupError.invalidPackage
        }
    }

    static func addingAttachmentByteCount(_ data: Data, to total: Int) throws -> Int {
        let (newTotal, overflow) = total.addingReportingOverflow(data.count)
        guard data.count <= Self.maximumAttachmentByteCount,
              !overflow,
              newTotal <= Self.maximumTotalAttachmentByteCount else {
            throw FullBackupError.packageTooLarge
        }
        return newTotal
    }

    private static func reportedSize(of wrapper: FileWrapper) throws -> Int {
        guard let size = wrapper.fileAttributes[FileAttributeKey.size.rawValue] as? NSNumber else {
            return 0
        }
        let value = size.int64Value
        guard value >= 0 else {
            throw FullBackupError.packageTooLarge
        }
        return Int(value)
    }
}

struct FullBackupSummary: Equatable {
    let createdAt: Date
    let recordCount: Int
    let attachmentCount: Int
}

/// 全量备份覆盖 SchemaV2 的 14 个非 AppMeta 模型；系统元数据在恢复时按当前版本重建。
/// ponytail: 当前归档在内存中组装；附件规模实测成为瓶颈时升级为流式 FileWrapper。
struct FullBackupService {
    static let currentFormatVersion = 1
    static let lastRestoreIDKey = "backup.lastRestoreID"
    static let defaultSafetyBackupURL = URL.applicationSupportDirectory
        .appending(path: "Backups", directoryHint: .isDirectory)
        .appending(path: "PreRestore.zanzanbackup", directoryHint: .isDirectory)

    let context: ModelContext
    let attachmentRootDirectory: URL
    let safetyBackupURL: URL

    init(
        context: ModelContext,
        attachmentRootDirectory: URL? = nil,
        safetyBackupURL: URL? = nil
    ) {
        self.context = context
        self.attachmentRootDirectory =
            attachmentRootDirectory ?? AttachmentStore.defaultRootDirectory
        self.safetyBackupURL = safetyBackupURL ?? Self.defaultSafetyBackupURL
    }

    func export(createdAt: Date = .now) throws -> ZanzanBackupPackage {
        try CompatibilityWriteGate.ensureCurrentAppCanWrite(in: context)
        let payload = try ZanzanBackupPayload(context: context)
        try payload.validateReferences()

        let referenced = payload.referencedAttachmentFileNames
        guard referenced.count == Set(referenced).count else {
            throw FullBackupError.duplicateAttachmentReference
        }
        guard referenced.count <= ZanzanBackupPackage.maximumAttachmentCount else {
            throw FullBackupError.packageTooLarge
        }
        let store = AttachmentStore(context: context, rootDirectory: attachmentRootDirectory)
        var attachments: [String: Data] = [:]
        var manifests: [ZanzanBackupAttachmentManifest] = []
        var totalAttachmentByteCount = 0
        for fileName in referenced.sorted() {
            try ZanzanBackupPackage.validateAttachmentFileName(fileName)
            let data = try store.load(fileName)
            totalAttachmentByteCount = try ZanzanBackupPackage.addingAttachmentByteCount(
                data,
                to: totalAttachmentByteCount
            )
            attachments[fileName] = data
            manifests.append(
                ZanzanBackupAttachmentManifest(
                    fileName: fileName,
                    byteCount: data.count,
                    sha256: Self.sha256(data)
                )
            )
        }

        let content = ZanzanBackupManifestContent(
            formatVersion: Self.currentFormatVersion,
            schemaVersion: CompatibilityWriteGate.currentVersionString,
            createdAt: createdAt,
            payload: payload,
            attachments: manifests
        )
        let package = ZanzanBackupPackage(
            manifest: try Self.encodeManifest(content),
            attachments: attachments
        )
        try package.validateResourceLimits()
        return package
    }

    @discardableResult
    func restore(
        _ package: ZanzanBackupPackage,
        createsSafetyBackup: Bool = true
    ) throws -> FullBackupSummary {
        try recoverInterruptedRestore()
        try CompatibilityWriteGate.ensureCurrentAppCanWrite(in: context)
        let content = try preflight(package)
        if createsSafetyBackup {
            try export().write(to: safetyBackupURL)
            _ = try preflight(ZanzanBackupPackage.read(from: safetyBackupURL))
        }

        let restoreID = UUID().uuidString
        try stageAttachments(package.attachments, restoreID: restoreID)
        do {
            try activateStagedAttachments()
            do {
                try replaceDatabase(with: content.payload, restoreID: restoreID)
            } catch let databaseError {
                do {
                    try rollBackAttachmentSwap()
                } catch {
                    throw FullBackupError.invalidRecoveryState
                }
                throw databaseError
            }
            do {
                try finalizeAttachmentSwap()
            } catch {
                throw FullBackupError.restoreCompletedCleanupPending
            }
        } catch {
            try? removeIfExists(stagingDirectory)
            throw error
        }

        return FullBackupSummary(
            createdAt: content.createdAt,
            recordCount: content.payload.recordCount,
            attachmentCount: content.attachments.count
        )
    }

    func loadSafetyBackup() throws -> ZanzanBackupPackage? {
        guard FileManager.default.fileExists(atPath: safetyBackupURL.path) else { return nil }
        return try ZanzanBackupPackage.read(from: safetyBackupURL)
    }

    /// 启动时收敛恢复中断：数据库中的 restoreID 决定保留新附件还是回退旧附件。
    func recoverInterruptedRestore() throws {
        let rootMarker = try restoreID(in: attachmentRootDirectory)
        let stagingMarker = try restoreID(in: stagingDirectory)
        let stagingExists = FileManager.default.fileExists(atPath: stagingDirectory.path)
        let rollbackExists = FileManager.default.fileExists(atPath: rollbackDirectory.path)
        guard rootMarker != nil || stagingMarker != nil || stagingExists || rollbackExists else {
            return
        }
        try CompatibilityWriteGate.ensureCurrentAppCanWrite(in: context)

        if stagingExists, stagingMarker == nil {
            try removeIfExists(stagingDirectory)
        }
        if rootMarker == nil, stagingMarker == nil {
            guard rollbackExists else { return }
            guard !FileManager.default.fileExists(atPath: attachmentRootDirectory.path) else {
                throw FullBackupError.invalidRecoveryState
            }
            try FileManager.default.moveItem(
                at: rollbackDirectory,
                to: attachmentRootDirectory
            )
            return
        }
        guard let candidate = rootMarker ?? stagingMarker,
              rootMarker == nil || stagingMarker == nil || rootMarker == stagingMarker else {
            throw FullBackupError.invalidRecoveryState
        }

        let key = Self.lastRestoreIDKey
        let committed = try context.fetch(
            FetchDescriptor<AppMeta>(predicate: #Predicate {
                !$0.isSoftDeleted && $0.key == key
            })
        ).contains { $0.value == candidate }

        if committed {
            if rootMarker == nil {
                guard stagingMarker == candidate,
                      !FileManager.default.fileExists(atPath: attachmentRootDirectory.path) else {
                    throw FullBackupError.invalidRecoveryState
                }
                try FileManager.default.moveItem(
                    at: stagingDirectory,
                    to: attachmentRootDirectory
                )
            } else {
                try removeIfExists(stagingDirectory)
            }
            try removeIfExists(rollbackDirectory)
            try removeRestoreMarker()
        } else {
            if rootMarker != nil {
                try removeIfExists(attachmentRootDirectory)
            }
            try removeIfExists(stagingDirectory)
            if rollbackExists {
                guard !FileManager.default.fileExists(atPath: attachmentRootDirectory.path) else {
                    throw FullBackupError.invalidRecoveryState
                }
                try FileManager.default.moveItem(
                    at: rollbackDirectory,
                    to: attachmentRootDirectory
                )
            }
        }
    }

    // MARK: - 归档预检

    private func preflight(_ package: ZanzanBackupPackage) throws
        -> ZanzanBackupManifestContent {
        try package.validateResourceLimits()
        let content = try Self.decodeManifest(package.manifest)
        guard content.formatVersion == Self.currentFormatVersion else {
            throw FullBackupError.unsupportedFormat(content.formatVersion)
        }
        guard let sourceVersion = CompatibilityWriteGate.version(from: content.schemaVersion) else {
            throw FullBackupError.invalidSchemaVersion(content.schemaVersion)
        }
        guard sourceVersion <= CompatibilityWriteGate.currentVersion else {
            throw FullBackupError.requiresNewerApp(content.schemaVersion)
        }

        try content.payload.validateReferences()
        let referenced = content.payload.referencedAttachmentFileNames
        guard referenced.count == Set(referenced).count else {
            throw FullBackupError.duplicateAttachmentReference
        }
        let manifestNames = content.attachments.map(\.fileName)
        guard manifestNames.count == Set(manifestNames).count else {
            throw FullBackupError.duplicateAttachmentManifest
        }
        guard Set(referenced) == Set(manifestNames),
              Set(package.attachments.keys) == Set(manifestNames) else {
            throw FullBackupError.attachmentSetMismatch
        }
        for manifest in content.attachments {
            try AttachmentStore.validateFileName(manifest.fileName)
            guard let data = package.attachments[manifest.fileName],
                  data.count == manifest.byteCount,
                  Self.sha256(data) == manifest.sha256 else {
                throw FullBackupError.attachmentIntegrityFailed(manifest.fileName)
            }
        }
        try validateInTemporaryStore(content.payload)
        return content
    }

    private func validateInTemporaryStore(_ payload: ZanzanBackupPayload) throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "ZanzanBackupValidation-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "validation.store")
        do {
            let container = try AppModelContainer.make(storeURL: storeURL)
            let validationContext = ModelContext(container)
            try validationContext.transaction {
                try payload.insertAll(into: validationContext)
                Self.insertSystemMetadata(into: validationContext, restoreID: nil)
            }
        }
        do {
            let reopened = try AppModelContainer.make(storeURL: storeURL)
            let reopenedPayload = try ZanzanBackupPayload(context: ModelContext(reopened))
            guard reopenedPayload == payload else {
                throw FullBackupError.temporaryStoreVerificationFailed
            }
        }
    }

    private static func encodeManifest(_ content: ZanzanBackupManifestContent) throws -> Data {
        let contentData = try canonicalData(content)
        return try canonicalEncoder.encode(
            ZanzanBackupManifestEnvelope(
                contentData: contentData,
                checksum: sha256(contentData)
            )
        )
    }

    private static func decodeManifest(_ data: Data) throws -> ZanzanBackupManifestContent {
        let envelope: ZanzanBackupManifestEnvelope
        do {
            envelope = try canonicalDecoder.decode(ZanzanBackupManifestEnvelope.self, from: data)
        } catch {
            throw FullBackupError.invalidManifest
        }
        guard sha256(envelope.contentData) == envelope.checksum else {
            throw FullBackupError.manifestIntegrityFailed
        }
        do {
            return try canonicalDecoder.decode(
                ZanzanBackupManifestContent.self,
                from: envelope.contentData
            )
        } catch {
            throw FullBackupError.invalidManifest
        }
    }

    private static var canonicalEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var canonicalDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        try canonicalEncoder.encode(value)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 数据库替换

    private func replaceDatabase(with payload: ZanzanBackupPayload, restoreID: String) throws {
        try CompatibilityWriteGate.ensureCurrentAppCanWrite(in: context)
        let previousAutosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = previousAutosave }
        do {
            try context.transaction {
                try deleteAllModels()
                try payload.insertAll(into: context)
                Self.insertSystemMetadata(into: context, restoreID: restoreID)
            }
        } catch {
            context.rollback()
            throw error
        }
    }

    private func deleteAllModels() throws {
        try deleteAll(TransactionLink.self)
        try deleteAll(InstallmentPeriod.self)
        try deleteAll(BalanceSnapshot.self)
        try deleteAll(Budget.self)
        try deleteAll(Transaction.self)
        try deleteAll(RecurringRule.self)
        try deleteAll(InstallmentPlan.self)
        try deleteAll(ImportBatch.self)
        try deleteAll(Tag.self)
        try deleteAll(Category.self)
        try deleteAll(Account.self)
        try deleteAll(CreditPool.self)
        try deleteAll(Ledger.self)
        try deleteAll(AuditLog.self)
        try deleteAll(AppMeta.self)
    }

    private func deleteAll<T: PersistentModel>(_ type: T.Type) throws {
        for model in try context.fetch(FetchDescriptor<T>()) {
            context.delete(model)
        }
    }

    private static func insertSystemMetadata(
        into context: ModelContext,
        restoreID: String?
    ) {
        context.insert(
            AppMeta(key: CompatibilityWriteGate.key, value: CompatibilityWriteGate.currentVersionString)
        )
        context.insert(AppMeta(key: DefaultDataSeeder.completionKey, value: "done"))
        if let restoreID {
            context.insert(AppMeta(key: lastRestoreIDKey, value: restoreID))
        }
    }

    // MARK: - 附件切换与恢复日志

    private var stagingDirectory: URL {
        attachmentRootDirectory.deletingLastPathComponent().appending(
            path: ".\(attachmentRootDirectory.lastPathComponent).restore-staging",
            directoryHint: .isDirectory
        )
    }

    private var rollbackDirectory: URL {
        attachmentRootDirectory.deletingLastPathComponent().appending(
            path: ".\(attachmentRootDirectory.lastPathComponent).restore-rollback",
            directoryHint: .isDirectory
        )
    }

    private var markerFileName: String { ".zanzan-restore-id" }

    private func stageAttachments(_ attachments: [String: Data], restoreID: String) throws {
        try removeIfExists(stagingDirectory)
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        do {
            try Data(restoreID.utf8).write(
                to: stagingDirectory.appending(path: markerFileName),
                options: .atomic
            )
            for (fileName, data) in attachments {
                try AttachmentStore.validateFileName(fileName)
                try data.write(
                    to: stagingDirectory.appending(path: fileName),
                    options: .atomic
                )
            }
        } catch {
            try? removeIfExists(stagingDirectory)
            throw error
        }
    }

    private func activateStagedAttachments() throws {
        try removeIfExists(rollbackDirectory)
        if FileManager.default.fileExists(atPath: attachmentRootDirectory.path) {
            try FileManager.default.moveItem(
                at: attachmentRootDirectory,
                to: rollbackDirectory
            )
        }
        do {
            try FileManager.default.moveItem(
                at: stagingDirectory,
                to: attachmentRootDirectory
            )
        } catch {
            if FileManager.default.fileExists(atPath: rollbackDirectory.path) {
                try? FileManager.default.moveItem(
                    at: rollbackDirectory,
                    to: attachmentRootDirectory
                )
            }
            throw error
        }
    }

    private func rollBackAttachmentSwap() throws {
        try removeIfExists(attachmentRootDirectory)
        if FileManager.default.fileExists(atPath: rollbackDirectory.path) {
            try FileManager.default.moveItem(
                at: rollbackDirectory,
                to: attachmentRootDirectory
            )
        }
        try removeIfExists(stagingDirectory)
    }

    private func finalizeAttachmentSwap() throws {
        try removeIfExists(rollbackDirectory)
        try removeIfExists(stagingDirectory)
        try removeRestoreMarker()
    }

    private func restoreID(in directory: URL) throws -> String? {
        let marker = directory.appending(path: markerFileName)
        guard FileManager.default.fileExists(atPath: marker.path) else { return nil }
        let value = try String(contentsOf: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: value) != nil else {
            throw FullBackupError.invalidRecoveryState
        }
        return value
    }

    private func removeRestoreMarker() throws {
        let marker = attachmentRootDirectory.appending(path: markerFileName)
        if FileManager.default.fileExists(atPath: marker.path) {
            try FileManager.default.removeItem(at: marker)
        }
    }

    private func removeIfExists(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

nonisolated enum FullBackupError: LocalizedError, Equatable {
    case invalidPackage
    case packageTooLarge
    case invalidManifest
    case manifestIntegrityFailed
    case unsupportedFormat(Int)
    case invalidSchemaVersion(String)
    case requiresNewerApp(String)
    case duplicateAttachmentReference
    case duplicateAttachmentManifest
    case attachmentSetMismatch
    case attachmentIntegrityFailed(String)
    case temporaryStoreVerificationFailed
    case invalidRecoveryState
    case restoreCompletedCleanupPending

    var errorDescription: String? {
        switch self {
        case .invalidPackage:
            ZanzanLocalization.string("备份包结构无效")
        case .packageTooLarge:
            ZanzanLocalization.string("备份包超过当前版本可安全处理的大小")
        case .invalidManifest:
            ZanzanLocalization.string("备份清单无法读取")
        case .manifestIntegrityFailed:
            ZanzanLocalization.string("备份清单校验失败，文件可能已损坏")
        case let .unsupportedFormat(version):
            ZanzanLocalization.string("不支持的备份格式版本：\(version)")
        case let .invalidSchemaVersion(version):
            ZanzanLocalization.string("备份数据库版本无效：\(version)")
        case let .requiresNewerApp(version):
            ZanzanLocalization.string("此备份需要更高版本的 App（数据库版本 \(version)）")
        case .duplicateAttachmentReference:
            ZanzanLocalization.string("备份中存在重复附件引用")
        case .duplicateAttachmentManifest:
            ZanzanLocalization.string("备份清单中存在重复附件")
        case .attachmentSetMismatch:
            ZanzanLocalization.string("备份附件与流水引用不一致")
        case let .attachmentIntegrityFailed(fileName):
            ZanzanLocalization.string("附件校验失败：\(fileName)")
        case .temporaryStoreVerificationFailed:
            ZanzanLocalization.string("备份恢复演练未通过，未修改当前数据")
        case .invalidRecoveryState:
            ZanzanLocalization.string("检测到无法自动收敛的恢复中断状态")
        case .restoreCompletedCleanupPending:
            ZanzanLocalization.string("数据已恢复，但临时文件清理未完成；重启 App 将自动重试")
        }
    }
}
