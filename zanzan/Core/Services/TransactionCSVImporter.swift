import CryptoKit
import Foundation
import SwiftData

/// 流水 CSV 导入（设计文档 §5.12）。列约定见 `TransactionCSV`。
///
/// 系统边界，外部数据一律不可信：逐行校验（列数/类型/金额/日期/账户/分类），
/// 错误带行号聚合上报。失败策略：**文档未规定行级跳过，取整批原子失败**——
/// 任一行非法则整批不落库，用户改好文件重导，避免"导了一半"的对账噩梦。
/// 落库逐笔走 `TransactionService` 完整校验，来源包 `sourceKind = csvImport,
/// sourceID = batch.uuid` 随首个 save 原子落库，支持 `undoBatch` 整批软删撤销（幂等）。
struct TransactionCSVImporter {
    let context: ModelContext

    /// 单次导入的数据行数上限：逐笔经 TransactionService 落库（每笔一次 save），
    /// 超大文件会长时间占主线程；超限整批拒绝，提示用户拆分文件
    static let maxImportRows = 10_000

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
        // 双格式表头：11 列新格式带多币种列；旧 8 列文件按 CNY 兼容读入
        let isLegacyFormat: Bool
        switch header {
        case TransactionCSV.headerColumns: isLegacyFormat = false
        case TransactionCSV.legacyHeaderColumns: isLegacyFormat = true
        default: throw TransactionCSVImportError.invalidHeader
        }
        let dataRows = Array(records.dropFirst())
        guard !dataRows.isEmpty else { throw TransactionCSVImportError.noDataRows }
        guard dataRows.count <= Self.maxImportRows else {
            throw TransactionCSVImportError.tooManyRows(limit: Self.maxImportRows)
        }
        try ensureActiveLedger(ledgerID)

        // 名称 → (uuid, 币种) 查找表（仅活跃实体）。ponytail: 同名取先建的一个，重名歧义不阻断
        let accountsByName = try activeAccountsByName()
        let categoryIDsByKey = try activeCategoryIDsByKindAndName()

        // 第一遍：全量逐行校验，聚合行级错误（原子策略的前提）
        var rowErrors: [RowError] = []
        var validatedRows: [ValidatedRow] = []
        for (offset, fields) in dataRows.enumerated() {
            let line = offset + 2 // 表头占第 1 行
            do {
                validatedRows.append(try validateRow(
                    fields, line: line, isLegacyFormat: isLegacyFormat,
                    accountsByName: accountsByName, categoryIDsByKey: categoryIDsByKey
                ))
            } catch let error as TransactionCSVImportError {
                rowErrors.append(RowError(line: line, message: error.localizedDescription))
            } catch {
                rowErrors.append(RowError(line: line, message: error.localizedDescription))
            }
        }
        guard rowErrors.isEmpty else { throw TransactionCSVImportError.invalidRows(rowErrors) }

        // 第二遍：先落批次行并 save，再逐笔经 TransactionService 落库（服务层二次完整校验）。
        // 顺序即崩溃防线：中途崩溃时批次行已可查——undoBatch 可清理半批流水，
        // 撞哈希检测也能命中，不留 sourceID 悬空的孤儿批。
        // recordTransaction 内部逐笔 save，无法收敛为批末一次事务 save；
        // 来源包经参数在每笔首个 save 前写入，半批流水均可被 undoBatch 按 sourceID 反查。
        let batch = ImportBatch(fileName: fileName, importedAt: importedAt)
        batch.contentHash = Self.contentHash(of: csv)
        context.insert(batch)
        try context.save()
        let service = TransactionService(context: context)
        var inserted: [Transaction] = []
        do {
            for row in validatedRows {
                inserted.append(try service.recordTransaction(
                    row.draft, ledgerID: ledgerID, source: (kind: .csvImport, id: batch.uuid)
                ))
            }
        } catch {
            // 预校验后此处理论不可达；兜底把已写入的半批连同批次行清掉再抛
            // （清理半批失败写入不算业务硬删除）
            for tx in inserted { context.delete(tx) }
            context.delete(batch)
            try? context.save()
            throw error
        }
        batch.transactionCount = inserted.count
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
        _ fields: [String], line: Int, isLegacyFormat: Bool,
        accountsByName: [String: (uuid: UUID, currencyCode: String, isArchived: Bool)],
        categoryIDsByKey: [String: (uuid: UUID, isArchived: Bool)]
    ) throws -> ValidatedRow {
        let expectedColumns = isLegacyFormat ? TransactionCSV.legacyColumnCount : TransactionCSV.columnCount
        guard fields.count == expectedColumns else {
            throw TransactionCSVImportError.wrongColumnCount(expected: expectedColumns, actual: fields.count)
        }
        let (dateString, kindLabel, amountString) = (fields[0], fields[1], fields[2])
        let (categoryName, accountName, targetAccountName) = (fields[3], fields[4], fields[5])
        let (feeString, note) = (fields[6], fields[7])
        // 旧格式无多币种列，按 CNY 兼容读入（币种空、汇率空、到账金额空）
        let currencyField = isLegacyFormat ? "" : fields[8].trimmingCharacters(in: .whitespaces)
        let fxRateString = isLegacyFormat ? "" : fields[9].trimmingCharacters(in: .whitespaces)
        let targetAmountString = isLegacyFormat ? "" : fields[10].trimmingCharacters(in: .whitespaces)
        let rowCurrency = currencyField.isEmpty ? FxConversion.baseCurrencyCode : currencyField

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
        // 手续费仅转账行可填（§5.4 fee 恒为转账流出）：非转账带手续费按行级错误报出，
        // 不再被 Draft 静默归零（同 targetAmountNotAllowed 口径）
        if kind != .transfer {
            guard trimmedFee.isEmpty else { throw TransactionCSVImportError.feeNotAllowed }
        } else if !trimmedFee.isEmpty, TransactionCSV.minorUnits(fromCSVAmount: trimmedFee) == nil {
            throw TransactionCSVImportError.invalidFee(feeString)
        }

        var draft = TransactionDraft()
        draft.kind = kind
        draft.amountString = amountString.trimmingCharacters(in: .whitespaces)
        draft.occurredAt = occurredAt
        draft.note = note
        draft.feeString = trimmedFee

        let trimmedAccountName = accountName.trimmingCharacters(in: .whitespaces)
        guard let account = accountsByName[trimmedAccountName] else {
            throw TransactionCSVImportError.accountNotFound(trimmedAccountName)
        }
        // §4 归档=新引用禁止，导入按默认阻断；导历史数据特例待产品裁决后放开
        guard !account.isArchived else {
            throw TransactionCSVImportError.accountArchived(trimmedAccountName)
        }
        draft.accountUUID = account.uuid
        // 流水币种由账户决定（§5.4：收支 = 账户币种，转账 = 转出方币种），行内不符即数据矛盾
        guard rowCurrency == account.currencyCode else {
            throw TransactionCSVImportError.currencyMismatch(row: rowCurrency, account: account.currencyCode)
        }
        // 汇率规则（§5.4）：外币行必填且 > 0；本位币行恒空（fxRateToBase 恒 nil）
        if rowCurrency == FxConversion.baseCurrencyCode {
            guard fxRateString.isEmpty else { throw TransactionCSVImportError.fxRateNotAllowed }
        } else {
            guard let rate = TransactionCSV.decimal(fromCSVRate: fxRateString), rate > 0 else {
                throw TransactionCSVImportError.invalidFxRate(fxRateString)
            }
        }

        var isCrossCurrencyTransfer = false
        switch kind {
        case .expense, .income:
            let trimmedCategoryName = categoryName.trimmingCharacters(in: .whitespaces)
            guard let category = categoryIDsByKey[categoryKey(kind, trimmedCategoryName)] else {
                throw TransactionCSVImportError.categoryNotFound(trimmedCategoryName)
            }
            // 同账户口径：归档分类阻断，否则预校验放行后会在服务层落库时被拒、击穿原子承诺
            guard !category.isArchived else {
                throw TransactionCSVImportError.categoryArchived(trimmedCategoryName)
            }
            draft.categoryUUID = category.uuid
        case .transfer:
            let trimmedTargetName = targetAccountName.trimmingCharacters(in: .whitespaces)
            guard let target = accountsByName[trimmedTargetName] else {
                throw TransactionCSVImportError.accountNotFound(trimmedTargetName)
            }
            guard !target.isArchived else {
                throw TransactionCSVImportError.accountArchived(trimmedTargetName)
            }
            draft.targetAccountUUID = target.uuid
            isCrossCurrencyTransfer = target.currencyCode != rowCurrency
        }
        // 到账金额规则（§5.4）：跨币种转账必填且 > 0（转入账户币种计）；其余行恒空
        if isCrossCurrencyTransfer {
            guard let targetAmount = TransactionCSV.minorUnits(fromCSVAmount: targetAmountString),
                  targetAmount > 0 else {
                throw TransactionCSVImportError.invalidTargetAmount(targetAmountString)
            }
        } else {
            guard targetAmountString.isEmpty else { throw TransactionCSVImportError.targetAmountNotAllowed }
        }
        // 契约字段：并行切片在 TransactionDraft 新增 fxRateString / targetAmountString，
        // validated 产出 fxRateToBase: Decimal? / targetAmountMinorUnits: Int?，此处按约定名赋值
        draft.fxRateString = fxRateString
        draft.targetAmountString = targetAmountString

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

    /// 归档实体保留在查找表并带 isArchived 标记：行级报"已归档"而非误报"不存在"
    private func activeAccountsByName() throws -> [String: (uuid: UUID, currencyCode: String, isArchived: Bool)] {
        let accounts = try context.fetch(
            FetchDescriptor<Account>(predicate: #Predicate { !$0.isSoftDeleted })
        )
        return accounts.reduce(into: [:]) { dict, account in
            if dict[account.name] == nil {
                dict[account.name] = (account.uuid, account.currencyCode, account.isArchived)
            }
        }
    }

    /// 分类查找表按 "方向|名称" 组合键——同名跨方向分类（如支出/收入各有"其他"）不串线，
    /// 方向不匹配自然查不到，报"分类不存在或方向不符"
    private func activeCategoryIDsByKindAndName() throws -> [String: (uuid: UUID, isArchived: Bool)] {
        let categories = try context.fetch(
            FetchDescriptor<Category>(predicate: #Predicate { !$0.isSoftDeleted })
        )
        return categories.reduce(into: [:]) { dict, category in
            let key = categoryKey(TransactionKind(rawValue: category.kindRawValue), category.name)
            if dict[key] == nil { dict[key] = (category.uuid, category.isArchived) }
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
    case feeNotAllowed
    case accountNotFound(String)
    case accountArchived(String)
    case categoryNotFound(String)
    case categoryArchived(String)
    case tooManyRows(limit: Int)
    case currencyMismatch(row: String, account: String)
    case invalidFxRate(String)
    case fxRateNotAllowed
    case invalidTargetAmount(String)
    case targetAmountNotAllowed
    case invalidRows([TransactionCSVImporter.RowError])
    case batchNotFound

    var errorDescription: String? {
        switch self {
        case .invalidHeader:
            String(localized: "表头不符，应为：日期,类型,金额,分类,账户,转入账户,手续费,备注,币种,汇率,到账金额（或不含后三列的旧格式）")
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
        case .feeNotAllowed:
            String(localized: "仅转账行可填写手续费")
        case let .accountNotFound(name):
            String(localized: "账户「\(name)」不存在或已删除")
        case let .accountArchived(name):
            String(localized: "账户「\(name)」已归档，请先取消归档再导入")
        case let .categoryNotFound(name):
            String(localized: "分类「\(name)」不存在或方向不符")
        case let .categoryArchived(name):
            String(localized: "分类「\(name)」已归档，请先取消归档再导入")
        case let .tooManyRows(limit):
            String(localized: "流水行数超过单次导入上限 \(limit) 行，请拆分文件后分批导入")
        case let .currencyMismatch(row, account):
            String(localized: "币种「\(row)」与账户币种「\(account)」不符")
        case let .invalidFxRate(value):
            String(localized: "汇率「\(value)」不正确（外币行须为大于 0 的十进制数）")
        case .fxRateNotAllowed:
            String(localized: "本位币（CNY）行不应填写汇率")
        case let .invalidTargetAmount(value):
            String(localized: "到账金额「\(value)」不正确（跨币种转账须为大于 0 的十进制数，最多两位小数）")
        case .targetAmountNotAllowed:
            String(localized: "仅跨币种转账行可填写到账金额")
        case let .invalidRows(errors):
            String(localized: "\(errors.count) 行数据有误，本次导入已整批取消")
        case .batchNotFound:
            String(localized: "导入批次不存在")
        }
    }
}
