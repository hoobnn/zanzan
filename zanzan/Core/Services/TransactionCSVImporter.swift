import CryptoKit
import Foundation
import SwiftData

/// 流水 CSV 导入（设计文档 §5.12）。列约定见 `TransactionCSV`。
///
/// 系统边界，外部数据一律不可信：逐行校验（列数/类型/金额/日期/账户/分类），
/// 错误带行号聚合上报。失败策略：**文档未规定行级跳过，取整批原子失败**——
/// 任一行非法则整批不落库，用户改好文件重导，避免"导了一半"的对账噩梦。
/// 落库逐笔走 `TransactionService` 完整校验，成功后打 `sourceKind = csvImport,
/// sourceID = batch.uuid`，支持 `undoBatch` 整批软删撤销（幂等）。
struct TransactionCSVImporter {
    let context: ModelContext

    /// 行级错误：line 为 CSV 文件内行号（表头为第 1 行）。
    /// nonisolated：纯值类型，Equatable 合成不得绑定 MainActor（Error 语境是 nonisolated）
    nonisolated struct RowError: Equatable {
        let line: Int
        let message: String
    }

    /// 校验通过的行（金额/日期已解析，引用已解析为 uuid）
    private struct ValidatedRow {
        let draft: TransactionDraft
    }

    // MARK: - 导入

    /// 解析并整批导入 CSV；importedAt 由调用方注入（禁 .now）。
    /// 返回创建的 `ImportBatch`；任一行校验失败抛 `invalidRows`，不写库。
    @discardableResult
    func importTransactions(
        csv: String, fileName: String, ledgerID: UUID, importedAt: Date
    ) throws -> ImportBatch {
        let records = try TransactionCSV.parse(csv)
        guard let header = records.first else { throw TransactionCSVImportError.noDataRows }
        guard header == TransactionCSV.headerColumns else { throw TransactionCSVImportError.invalidHeader }
        let dataRows = Array(records.dropFirst())
        guard !dataRows.isEmpty else { throw TransactionCSVImportError.noDataRows }
        try ensureActiveLedger(ledgerID)

        // 名称 → uuid 查找表（仅活跃实体）。ponytail: 同名取先建的一个，重名歧义不阻断
        let accountIDsByName = try activeAccountIDsByName()
        let categoryIDsByKey = try activeCategoryIDsByKindAndName()

        // 第一遍：全量逐行校验，聚合行级错误（原子策略的前提）
        var rowErrors: [RowError] = []
        var validatedRows: [ValidatedRow] = []
        for (offset, fields) in dataRows.enumerated() {
            let line = offset + 2 // 表头占第 1 行
            do {
                validatedRows.append(try validateRow(
                    fields, line: line,
                    accountIDsByName: accountIDsByName, categoryIDsByKey: categoryIDsByKey
                ))
            } catch let error as TransactionCSVImportError {
                rowErrors.append(RowError(line: line, message: error.localizedDescription))
            } catch {
                rowErrors.append(RowError(line: line, message: error.localizedDescription))
            }
        }
        guard rowErrors.isEmpty else { throw TransactionCSVImportError.invalidRows(rowErrors) }

        // 第二遍：逐笔经 TransactionService 落库（服务层二次完整校验）
        let batch = ImportBatch(fileName: fileName, importedAt: importedAt)
        batch.contentHash = Self.contentHash(of: csv)
        let service = TransactionService(context: context)
        var inserted: [Transaction] = []
        do {
            for row in validatedRows {
                let tx = try service.recordTransaction(row.draft, ledgerID: ledgerID)
                tx.sourceKindRawValue = TransactionSourceKind.csvImport.rawValue
                tx.sourceID = batch.uuid
                inserted.append(tx)
            }
        } catch {
            // recordTransaction 逐笔 save，无事务可回滚；预校验后此处理论不可达，
            // 兜底把已写入的半批清掉再抛（清理半批失败写入不算业务硬删除）
            for tx in inserted { context.delete(tx) }
            try? context.save()
            throw error
        }
        batch.transactionCount = inserted.count
        context.insert(batch)
        try context.save()
        return batch
    }

    // MARK: - 整批撤销

    /// 整批撤销：软删批次内全部流水与批次本身。幂等——重复调用不报错、结果不变。
    func undoBatch(batchUUID: UUID) throws {
        let batchDescriptor = FetchDescriptor<ImportBatch>(predicate: #Predicate { $0.uuid == batchUUID })
        guard let batch = try context.fetch(batchDescriptor).first else {
            throw TransactionCSVImportError.batchNotFound
        }
        let csvImportRaw = TransactionSourceKind.csvImport.rawValue
        let txDescriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate {
                !$0.isSoftDeleted && $0.sourceID == batchUUID && $0.sourceKindRawValue == csvImportRaw
            }
        )
        for tx in try context.fetch(txDescriptor) {
            tx.isSoftDeleted = true
            tx.updatedAt = .now
        }
        if !batch.isSoftDeleted {
            batch.isSoftDeleted = true
            batch.updatedAt = .now
        }
        try context.save()
    }

    // MARK: - 重复导入检测（§5.12 撞哈希警告）

    /// CSV 内容 SHA-256（十六进制小写），落 `ImportBatch.contentHash`
    static func contentHash(of csv: String) -> String {
        SHA256.hash(data: Data(csv.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 查同哈希的活跃批次；非 nil 时 UI 应警告"疑似重复导入"（警告不阻断，由调用方决策）
    func existingBatch(withContentHash hash: String) throws -> ImportBatch? {
        let descriptor = FetchDescriptor<ImportBatch>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.contentHash == hash }
        )
        return try context.fetch(descriptor).first
    }

    // MARK: - 行校验

    private func validateRow(
        _ fields: [String], line: Int,
        accountIDsByName: [String: UUID], categoryIDsByKey: [String: UUID]
    ) throws -> ValidatedRow {
        guard fields.count == TransactionCSV.columnCount else {
            throw TransactionCSVImportError.wrongColumnCount(expected: TransactionCSV.columnCount, actual: fields.count)
        }
        let (dateString, kindLabel, amountString) = (fields[0], fields[1], fields[2])
        let (categoryName, accountName, targetAccountName) = (fields[3], fields[4], fields[5])
        let (feeString, note) = (fields[6], fields[7])

        guard let kind = TransactionCSV.kindByLabel[kindLabel.trimmingCharacters(in: .whitespaces)] else {
            throw TransactionCSVImportError.unknownKind(kindLabel)
        }
        guard let occurredAt = parseDate(dateString) else {
            throw TransactionCSVImportError.invalidDate(dateString)
        }
        // 金额/手续费先过严格解析（拒千分位逗号等静默错值），再以净化串进 Draft 统一走 MoneyAmount
        guard TransactionCSV.minorUnits(fromCSVAmount: amountString) != nil else {
            throw TransactionCSVImportError.invalidAmount(amountString)
        }
        let trimmedFee = feeString.trimmingCharacters(in: .whitespaces)
        if !trimmedFee.isEmpty, TransactionCSV.minorUnits(fromCSVAmount: trimmedFee) == nil {
            throw TransactionCSVImportError.invalidFee(feeString)
        }

        var draft = TransactionDraft()
        draft.kind = kind
        draft.amountString = amountString.trimmingCharacters(in: .whitespaces)
        draft.occurredAt = occurredAt
        draft.note = note
        draft.feeString = trimmedFee

        let trimmedAccountName = accountName.trimmingCharacters(in: .whitespaces)
        guard let accountUUID = accountIDsByName[trimmedAccountName] else {
            throw TransactionCSVImportError.accountNotFound(trimmedAccountName)
        }
        draft.accountUUID = accountUUID

        switch kind {
        case .expense, .income:
            let trimmedCategoryName = categoryName.trimmingCharacters(in: .whitespaces)
            guard let categoryUUID = categoryIDsByKey[categoryKey(kind, trimmedCategoryName)] else {
                throw TransactionCSVImportError.categoryNotFound(trimmedCategoryName)
            }
            draft.categoryUUID = categoryUUID
        case .transfer:
            let trimmedTargetName = targetAccountName.trimmingCharacters(in: .whitespaces)
            guard let targetUUID = accountIDsByName[trimmedTargetName] else {
                throw TransactionCSVImportError.accountNotFound(trimmedTargetName)
            }
            draft.targetAccountUUID = targetUUID
        }
        _ = try draft.validated() // Draft 侧兜底校验（金额>0、自转禁止等），错误原样上抛进行级报告
        return ValidatedRow(draft: draft)
    }

    private func parseDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        return TransactionCSV.dateFormatter.date(from: trimmed)
            ?? TransactionCSV.shortDateFormatter.date(from: trimmed)
    }

    // MARK: - 查找表与前置检查

    private func ensureActiveLedger(_ uuid: UUID) throws {
        let count = try context.fetchCount(
            FetchDescriptor<Ledger>(predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid })
        )
        guard count > 0 else { throw TransactionServiceError.ledgerNotFound }
    }

    private func activeAccountIDsByName() throws -> [String: UUID] {
        let accounts = try context.fetch(
            FetchDescriptor<Account>(predicate: #Predicate { !$0.isSoftDeleted })
        )
        return accounts.reduce(into: [:]) { dict, account in
            if dict[account.name] == nil { dict[account.name] = account.uuid }
        }
    }

    /// 分类查找表按 "方向|名称" 组合键——同名跨方向分类（如支出/收入各有"其他"）不串线，
    /// 方向不匹配自然查不到，报"分类不存在或方向不符"
    private func activeCategoryIDsByKindAndName() throws -> [String: UUID] {
        let categories = try context.fetch(
            FetchDescriptor<Category>(predicate: #Predicate { !$0.isSoftDeleted })
        )
        return categories.reduce(into: [:]) { dict, category in
            let key = categoryKey(TransactionKind(rawValue: category.kindRawValue), category.name)
            if dict[key] == nil { dict[key] = category.uuid }
        }
    }

    private func categoryKey(_ kind: TransactionKind?, _ name: String) -> String {
        "\(kind?.rawValue ?? "?")|\(name)"
    }
}

nonisolated enum TransactionCSVImportError: LocalizedError, Equatable {
    case invalidHeader
    case noDataRows
    case wrongColumnCount(expected: Int, actual: Int)
    case unknownKind(String)
    case invalidDate(String)
    case invalidAmount(String)
    case invalidFee(String)
    case accountNotFound(String)
    case categoryNotFound(String)
    case invalidRows([TransactionCSVImporter.RowError])
    case batchNotFound

    var errorDescription: String? {
        switch self {
        case .invalidHeader:
            String(localized: "表头不符，应为：日期,类型,金额,分类,账户,转入账户,手续费,备注")
        case .noDataRows:
            String(localized: "文件中没有可导入的流水行")
        case let .wrongColumnCount(expected, actual):
            String(localized: "列数不符，应为 \(expected) 列，实际 \(actual) 列")
        case let .unknownKind(label):
            String(localized: "类型「\(label)」无法识别（仅支持：支出/收入/转账）")
        case let .invalidDate(value):
            String(localized: "日期「\(value)」格式不正确（应为 yyyy-MM-dd 或 yyyy-MM-dd HH:mm:ss）")
        case let .invalidAmount(value):
            String(localized: "金额「\(value)」不正确（应为不含千分位的十进制数，最多两位小数）")
        case let .invalidFee(value):
            String(localized: "手续费「\(value)」不正确（应为不含千分位的十进制数，最多两位小数）")
        case let .accountNotFound(name):
            String(localized: "账户「\(name)」不存在或已删除")
        case let .categoryNotFound(name):
            String(localized: "分类「\(name)」不存在或方向不符")
        case let .invalidRows(errors):
            String(localized: "\(errors.count) 行数据有误，本次导入已整批取消")
        case .batchNotFound:
            String(localized: "导入批次不存在")
        }
    }
}
