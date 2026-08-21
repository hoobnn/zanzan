import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct TransactionCSVImporterTests {
    private struct Fixture {
        let context: ModelContext
        let ledger: Ledger
        let cash: Account
        let card: Account
        let dining: Category
    }

    private func makeFixture() throws -> Fixture {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let ledger = try LedgerService(context: context).createLedger(LedgerDraft(name: "日常"))
        let cash = Account(name: "现金", kind: .fund)
        let card = Account(name: "储蓄卡", kind: .fund)
        let dining = Category(name: "餐饮", kind: .expense, sortOrder: 0)
        context.insert(cash)
        context.insert(card)
        context.insert(dining)
        try context.save()
        return Fixture(context: context, ledger: ledger, cash: cash, card: card, dining: dining)
    }

    /// 旧 8 列格式表头（多数既有用例沿用它，本身即旧格式兼容回归）
    private let header = "日期,类型,金额,分类,账户,转入账户,手续费,备注"
    /// 新 11 列格式表头（多币种列）
    private let headerV2 = "日期,类型,金额,分类,账户,转入账户,手续费,备注,币种,汇率,到账金额"
    private let importedAt = TransactionCSV.dateFormatter.date(from: "2026-02-01 10:00:00")!

    /// 建 USD 账户（外币行校验用）
    private func makeUSDAccount(_ f: Fixture) throws -> Account {
        let usd = Account(name: "美元卡", kind: .fund)
        usd.currencyCode = "USD"
        f.context.insert(usd)
        try f.context.save()
        return usd
    }

    private func activeTransactionCount(_ context: ModelContext) throws -> Int {
        try context.fetchCount(FetchDescriptor<Transaction>(predicate: #Predicate { !$0.isSoftDeleted }))
    }

    private func activeSnapshotCount(_ context: ModelContext, accountUUID: UUID) throws -> Int {
        try context.fetchCount(FetchDescriptor<BalanceSnapshot>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.accountID == accountUUID }
        ))
    }

    @Test func 成功导入建批次并挂来源() throws {
        let f = try makeFixture()
        let csv = """
        \(header)
        2026-01-05 12:30:00,支出,25.50,餐饮,现金,,,午饭
        2026-01-06,转账,100,,现金,储蓄卡,0.50,
        """
        let importer = TransactionCSVImporter(context: f.context)
        let batch = try importer.importTransactions(
            csv: csv, fileName: "bill.csv", ledgerID: f.ledger.uuid, importedAt: importedAt
        )
        #expect(batch.fileName == "bill.csv")
        #expect(batch.transactionCount == 2)
        #expect(batch.importedAt == importedAt)
        #expect(batch.contentHash == TransactionCSVImporter.contentHash(of: csv))

        let batchUUID = batch.uuid
        let txs = try f.context.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.sourceID == batchUUID },
            sortBy: [SortDescriptor(\.occurredAt, order: .forward)]
        ))
        #expect(txs.count == 2)
        #expect(txs.allSatisfy { $0.sourceKind == .csvImport })
        #expect(txs[0].amountMinorUnits == 2_550)
        #expect(txs[0].note == "午饭")
        #expect(txs[1].kind == .transfer)
        #expect(txs[1].feeMinorUnits == 50)
        // 仅日期格式按当天零点解析
        #expect(txs[1].occurredAt == TransactionCSV.shortDateFormatter.date(from: "2026-01-06"))
        // 旧 8 列格式按 CNY 兼容读入：币种取账户（CNY），无汇率/到账金额
        #expect(txs.allSatisfy { $0.currencyCode == "CNY" && $0.fxRateToBase == nil && $0.targetAmountMinorUnits == nil })
    }

    @Test func 金额精度定点解析不走Double() throws {
        let f = try makeFixture()
        let csv = """
        \(header)
        2026-01-01,支出,0.10,餐饮,现金,,,
        2026-01-02,支出,1234.56,餐饮,现金,,,
        2026-01-03,支出,.5,餐饮,现金,,,
        """
        let batch = try TransactionCSVImporter(context: f.context).importTransactions(
            csv: csv, fileName: "a.csv", ledgerID: f.ledger.uuid, importedAt: importedAt
        )
        let batchUUID = batch.uuid
        let txs = try f.context.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.sourceID == batchUUID },
            sortBy: [SortDescriptor(\.occurredAt, order: .forward)]
        ))
        #expect(txs.map(\.amountMinorUnits) == [10, 123_456, 50])
    }

    @Test func 千分位逗号金额被拒绝() throws {
        let f = try makeFixture()
        // "1,234.56" 带引号才是一个字段；约定不允许千分位，须行级报错而非静默解析成 1 元
        let csv = """
        \(header)
        2026-01-01,支出,"1,234.56",餐饮,现金,,,
        """
        #expect(throws: TransactionCSVImportError.self) {
            try TransactionCSVImporter(context: f.context).importTransactions(
                csv: csv, fileName: "a.csv", ledgerID: f.ledger.uuid, importedAt: self.importedAt
            )
        }
        #expect(try activeTransactionCount(f.context) == 0)
    }

    @Test func 非法行聚合报错且带行号() throws {
        let f = try makeFixture()
        let csv = """
        \(header)
        2026-01-01,支出,10,餐饮,现金,,,合法行
        2026-01-02,支出,abc,餐饮,现金,,,金额非法
        2026-13-40,支出,10,餐饮,现金,,,日期非法
        2026-01-04,吃饭,10,餐饮,现金,,,类型未知
        2026-01-05,支出,10,不存在的分类,现金,,,分类缺失
        2026-01-06,支出,10,餐饮,不存在的账户,,,账户缺失
        2026-01-07,支出,10,餐饮,现金,,列缺失
        """
        do {
            try TransactionCSVImporter(context: f.context).importTransactions(
                csv: csv, fileName: "a.csv", ledgerID: f.ledger.uuid, importedAt: importedAt
            )
            Issue.record("应整批失败")
        } catch let TransactionCSVImportError.invalidRows(errors) {
            #expect(errors.map(\.line) == [3, 4, 5, 6, 7, 8])
        }
        // 整批原子失败：连同合法的第 2 行也不落库
        #expect(try activeTransactionCount(f.context) == 0)
        #expect(try f.context.fetchCount(FetchDescriptor<ImportBatch>()) == 0)
    }

    @Test func 同名账户歧义整批拒绝且零写入() throws {
        let f = try makeFixture()
        f.context.insert(Account(name: "现金", kind: .fund))
        try f.context.save()
        let csv = """
        \(header)
        2026-01-01,支出,10,餐饮,现金,,,同名账户
        """

        do {
            try TransactionCSVImporter(context: f.context).importTransactions(
                csv: csv, fileName: "duplicate-account.csv",
                ledgerID: f.ledger.uuid, importedAt: importedAt
            )
            Issue.record("同名账户应作为行级歧义整批拒绝")
        } catch let TransactionCSVImportError.invalidRows(errors) {
            #expect(errors.map(\.line) == [2])
            #expect(errors[0].message == "账户「现金」存在多个同名候选，无法确定")
        }
        #expect(try activeTransactionCount(f.context) == 0)
        #expect(try f.context.fetchCount(FetchDescriptor<ImportBatch>()) == 0)
    }

    @Test func 分类方向不符按不存在处理() throws {
        let f = try makeFixture()
        let salary = Category(name: "工资", kind: .income, sortOrder: 0)
        f.context.insert(salary)
        try f.context.save()
        let csv = """
        \(header)
        2026-01-01,支出,10,工资,现金,,,支出挂收入分类
        """
        do {
            try TransactionCSVImporter(context: f.context).importTransactions(
                csv: csv, fileName: "a.csv", ledgerID: f.ledger.uuid, importedAt: importedAt
            )
            Issue.record("应整批失败")
        } catch let TransactionCSVImportError.invalidRows(errors) {
            #expect(errors.count == 1)
            #expect(errors[0].line == 2)
        }
    }

    @Test func 同方向同名分类歧义整批拒绝且零写入() throws {
        let f = try makeFixture()
        f.context.insert(Category(name: "餐饮", kind: .expense, sortOrder: 1))
        try f.context.save()
        let csv = """
        \(header)
        2026-01-01,支出,10,餐饮,现金,,,同名分类
        """

        do {
            try TransactionCSVImporter(context: f.context).importTransactions(
                csv: csv, fileName: "duplicate-category.csv",
                ledgerID: f.ledger.uuid, importedAt: importedAt
            )
            Issue.record("同方向同名分类应作为行级歧义整批拒绝")
        } catch let TransactionCSVImportError.invalidRows(errors) {
            #expect(errors.map(\.line) == [2])
            #expect(errors[0].message == "分类「餐饮」存在多个同名候选，无法确定")
        }
        #expect(try activeTransactionCount(f.context) == 0)
        #expect(try f.context.fetchCount(FetchDescriptor<ImportBatch>()) == 0)
    }

    // MARK: - 多币种列（币种/汇率/到账金额）

    @Test func 新格式外币行与跨币种转账导入() throws {
        let f = try makeFixture()
        _ = try makeUSDAccount(f)
        let csv = """
        \(headerV2)
        2026-01-05 12:00:00,支出,100,餐饮,美元卡,,,午饭,USD,7.2,
        2026-01-06 12:00:00,转账,720,,现金,美元卡,,,CNY,,100
        2026-01-07 12:00:00,支出,10,餐饮,现金,,,,CNY,,
        """
        let batch = try TransactionCSVImporter(context: f.context).importTransactions(
            csv: csv, fileName: "fx.csv", ledgerID: f.ledger.uuid, importedAt: importedAt
        )
        let batchUUID = batch.uuid
        let txs = try f.context.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.sourceID == batchUUID },
            sortBy: [SortDescriptor(\.occurredAt, order: .forward)]
        ))
        #expect(txs.count == 3)
        #expect(txs[0].currencyCode == "USD")
        #expect(txs[0].fxRateToBase == Decimal(string: "7.2")!)
        #expect(txs[1].kind == .transfer)
        #expect(txs[1].targetAmountMinorUnits == 10_000) // 到账 $100（转入账户币种计）
        #expect(txs[2].currencyCode == "CNY")
        #expect(txs[2].fxRateToBase == nil)
    }

    @Test func 多币种非法行聚合报错() throws {
        let f = try makeFixture()
        _ = try makeUSDAccount(f)
        let csv = """
        \(headerV2)
        2026-01-01,支出,10,餐饮,美元卡,,,外币缺汇率,USD,,
        2026-01-02,支出,10,餐饮,美元卡,,,汇率非正,USD,0,
        2026-01-03,支出,10,餐饮,美元卡,,,汇率非法,USD,7.2e3,
        2026-01-04,支出,10,餐饮,现金,,,币种与账户不符,USD,7.2,
        2026-01-05,支出,10,餐饮,现金,,,本位币行带汇率,CNY,7.2,
        2026-01-06,转账,720,,现金,美元卡,,跨币种转账缺到账金额,CNY,,
        2026-01-07,支出,10,餐饮,现金,,,非转账带到账金额,CNY,,10
        2026-01-08,转账,10,,现金,储蓄卡,,同币种转账带到账金额,CNY,,10
        """
        do {
            try TransactionCSVImporter(context: f.context).importTransactions(
                csv: csv, fileName: "fx.csv", ledgerID: f.ledger.uuid, importedAt: importedAt
            )
            Issue.record("应整批失败")
        } catch let TransactionCSVImportError.invalidRows(errors) {
            #expect(errors.map(\.line) == [2, 3, 4, 5, 6, 7, 8, 9])
        }
        #expect(try activeTransactionCount(f.context) == 0)
    }

    @Test func 旧格式引用外币账户按币种不符阻断() throws {
        let f = try makeFixture()
        _ = try makeUSDAccount(f)
        // 旧 8 列格式按 CNY 兼容读入，但账户是 USD → 行级报币种不符（旧格式装不下外币数据）
        let csv = header + "\n2026-01-01,支出,10,餐饮,美元卡,,,\n"
        do {
            try TransactionCSVImporter(context: f.context).importTransactions(
                csv: csv, fileName: "fx.csv", ledgerID: f.ledger.uuid, importedAt: importedAt
            )
            Issue.record("应整批失败")
        } catch let TransactionCSVImportError.invalidRows(errors) {
            #expect(errors.map(\.line) == [2])
        }
    }

    @Test func 表头不符与空文件被拒() throws {
        let f = try makeFixture()
        let importer = TransactionCSVImporter(context: f.context)
        #expect(throws: TransactionCSVImportError.invalidHeader) {
            try importer.importTransactions(
                csv: "日期,金额\n2026-01-01,10\n", fileName: "a.csv",
                ledgerID: f.ledger.uuid, importedAt: self.importedAt
            )
        }
        #expect(throws: TransactionCSVImportError.noDataRows) {
            try importer.importTransactions(
                csv: self.header + "\n", fileName: "a.csv",
                ledgerID: f.ledger.uuid, importedAt: self.importedAt
            )
        }
    }

    @Test func 引号未闭合抛格式错误() throws {
        let f = try makeFixture()
        let csv = header + "\n2026-01-01,支出,10,餐饮,现金,,,\"未闭合"
        #expect(throws: TransactionCSVError.self) {
            try TransactionCSVImporter(context: f.context).importTransactions(
                csv: csv, fileName: "a.csv", ledgerID: f.ledger.uuid, importedAt: self.importedAt
            )
        }
    }

    @Test func 账本不存在被拒() throws {
        let f = try makeFixture()
        let csv = header + "\n2026-01-01,支出,10,餐饮,现金,,,\n"
        #expect(throws: TransactionServiceError.self) {
            try TransactionCSVImporter(context: f.context).importTransactions(
                csv: csv, fileName: "a.csv", ledgerID: UUID(), importedAt: self.importedAt
            )
        }
    }

    @Test func 归档账本在预校验阶段拒绝且零写入() throws {
        let f = try makeFixture()
        f.ledger.isArchived = true
        try f.context.save()
        let csv = header + "\n2026-01-01,支出,10,餐饮,现金,,,归档账本\n"

        #expect(throws: TransactionCSVImportError.ledgerArchived) {
            try TransactionCSVImporter(context: f.context).importTransactions(
                csv: csv, fileName: "archived-ledger.csv",
                ledgerID: f.ledger.uuid, importedAt: self.importedAt
            )
        }
        #expect(try activeTransactionCount(f.context) == 0)
        #expect(try f.context.fetchCount(FetchDescriptor<ImportBatch>()) == 0)
    }

    @Test func 整批撤销软删流水与批次且幂等() throws {
        let f = try makeFixture()
        let csv = """
        \(header)
        2026-01-01,支出,10,餐饮,现金,,,
        2026-01-02,支出,20,餐饮,现金,,,
        """
        let importer = TransactionCSVImporter(context: f.context)
        let batch = try importer.importTransactions(
            csv: csv, fileName: "a.csv", ledgerID: f.ledger.uuid, importedAt: importedAt
        )
        #expect(try activeTransactionCount(f.context) == 2)

        try importer.undoBatch(batchUUID: batch.uuid)
        #expect(try activeTransactionCount(f.context) == 0)
        #expect(batch.isSoftDeleted)

        // 幂等：重复撤销不报错、结果不变
        try importer.undoBatch(batchUUID: batch.uuid)
        #expect(try activeTransactionCount(f.context) == 0)
        #expect(batch.isSoftDeleted)
        // 软删是软删不是硬删：数据仍在
        #expect(try f.context.fetchCount(FetchDescriptor<Transaction>()) == 2)
    }

    @Test func 整批恢复只恢复本次撤销的流水() throws {
        let f = try makeFixture()
        let csv = """
        \(header)
        2026-01-01,支出,10,餐饮,现金,,,此前单独删除
        2026-01-02,支出,20,餐饮,现金,,,随批次撤销
        """
        let importer = TransactionCSVImporter(context: f.context)
        let batch = try importer.importTransactions(
            csv: csv, fileName: "restore.csv",
            ledgerID: f.ledger.uuid, importedAt: importedAt
        )
        let batchUUID = batch.uuid
        let transactions = try f.context.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.sourceID == batchUUID },
            sortBy: [SortDescriptor(\.occurredAt)]
        ))
        let individuallyDeleted = try #require(transactions.first)
        let batchDeleted = try #require(transactions.last)
        try TransactionService(context: f.context)
            .softDeleteTransaction(uuid: individuallyDeleted.uuid)
        individuallyDeleted.updatedAt = importedAt
        try f.context.save()
        try importer.undoBatch(batchUUID: batch.uuid)

        try importer.restoreBatch(batchUUID: batch.uuid)

        #expect(!batch.isSoftDeleted)
        #expect(individuallyDeleted.isSoftDeleted)
        #expect(!batchDeleted.isSoftDeleted)
        #expect(try activeTransactionCount(f.context) == 1)
    }

    @Test func 整批恢复重复调用幂等且不改更新时间() throws {
        let f = try makeFixture()
        let csv = header + "\n2026-01-01,支出,10,餐饮,现金,,,\n"
        let importer = TransactionCSVImporter(context: f.context)
        let batch = try importer.importTransactions(
            csv: csv, fileName: "idempotent.csv",
            ledgerID: f.ledger.uuid, importedAt: importedAt
        )
        let batchUUID = batch.uuid
        let transaction = try #require(try f.context.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.sourceID == batchUUID }
        )).first)
        try importer.undoBatch(batchUUID: batch.uuid)
        try importer.restoreBatch(batchUUID: batch.uuid)
        let batchUpdatedAt = batch.updatedAt
        let transactionUpdatedAt = transaction.updatedAt

        try importer.restoreBatch(batchUUID: batch.uuid)

        #expect(!batch.isSoftDeleted)
        #expect(!transaction.isSoftDeleted)
        #expect(batch.updatedAt == batchUpdatedAt)
        #expect(transaction.updatedAt == transactionUpdatedAt)
    }

    @Test func 整批恢复引用失效时零部分写入() throws {
        let f = try makeFixture()
        let csv = """
        \(header)
        2026-01-01,支出,10,餐饮,现金,,,引用有效
        2026-01-02,支出,20,餐饮,储蓄卡,,,引用随后失效
        """
        let importer = TransactionCSVImporter(context: f.context)
        let batch = try importer.importTransactions(
            csv: csv, fileName: "invalid-reference.csv",
            ledgerID: f.ledger.uuid, importedAt: importedAt
        )
        try importer.undoBatch(batchUUID: batch.uuid)
        f.card.isSoftDeleted = true
        try f.context.save()

        do {
            try importer.restoreBatch(batchUUID: batch.uuid)
            Issue.record("任一流水引用失效时应整批拒绝恢复")
        } catch TransactionServiceError.restoreReferenceDeleted {
            // 预期错误
        } catch {
            Issue.record("错误类型不符：\(error)")
        }

        #expect(batch.isSoftDeleted)
        #expect(try activeTransactionCount(f.context) == 0)
        let batchUUID = batch.uuid
        #expect(try f.context.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.sourceID == batchUUID }
        )).allSatisfy(\.isSoftDeleted))
    }

    @Test func 整批恢复遇到账单标记时不绕过报销状态机() throws {
        let f = try makeFixture()
        let importer = TransactionCSVImporter(context: f.context)
        let batch = try importer.importTransactions(
            csv: header + "\n2026-01-01,支出,10,餐饮,现金,,,到账标记损坏\n",
            fileName: "settlement-guard.csv",
            ledgerID: f.ledger.uuid,
            importedAt: importedAt
        )
        try importer.undoBatch(batchUUID: batch.uuid)
        let batchUUID = batch.uuid
        let transaction = try #require(try f.context.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.sourceID == batchUUID }
        )).first)
        transaction.settlementKindRawValue = TransactionLinkKind.reimbursement.rawValue
        try f.context.save()

        #expect(throws: TransactionServiceError.managedByReimbursement) {
            try importer.restoreBatch(batchUUID: batch.uuid)
        }
        #expect(batch.isSoftDeleted)
        #expect(transaction.isSoftDeleted)
    }

    @Test func 整批恢复按最早时点失效转账双方快照() throws {
        let f = try makeFixture()
        let importer = TransactionCSVImporter(context: f.context)
        let snapshotService = BalanceSnapshotService(context: f.context)
        let midSnapshotAt = TransactionCSV.shortDateFormatter.date(from: "2026-01-10")!
        let lateSnapshotAt = TransactionCSV.shortDateFormatter.date(from: "2026-01-31")!
        let csv = """
        \(header)
        2026-01-05,转账,10,,现金,储蓄卡,0.10,早期
        2026-01-20,转账,20,,现金,储蓄卡,0.20,晚期
        """
        let batch = try importer.importTransactions(
            csv: csv, fileName: "restore-snapshots.csv",
            ledgerID: f.ledger.uuid, importedAt: importedAt
        )
        try importer.undoBatch(batchUUID: batch.uuid)
        for account in [f.cash, f.card] {
            try snapshotService.generateSnapshot(accountUUID: account.uuid, asOf: midSnapshotAt)
            try snapshotService.generateSnapshot(accountUUID: account.uuid, asOf: lateSnapshotAt)
        }

        try importer.restoreBatch(batchUUID: batch.uuid)

        #expect(try activeSnapshotCount(f.context, accountUUID: f.cash.uuid) == 0)
        #expect(try activeSnapshotCount(f.context, accountUUID: f.card.uuid) == 0)
    }

    @Test func 活跃报销退款关联阻断整批撤销且不留下悬空关联() throws {
        let f = try makeFixture()
        let csv = """
        \(header)
        2026-01-01,支出,10,餐饮,现金,,,待退款原单
        """
        let importer = TransactionCSVImporter(context: f.context)
        let batch = try importer.importTransactions(
            csv: csv, fileName: "linked.csv", ledgerID: f.ledger.uuid, importedAt: importedAt
        )
        let batchUUID = batch.uuid
        let imported = try #require(try f.context.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.sourceID == batchUUID }
        )).first)
        let settlement = try ReimbursementService(context: f.context).recordSettlement(
            kind: .refund,
            amountMinorUnits: imported.amountMinorUnits,
            occurredAt: importedAt,
            accountUUID: f.cash.uuid,
            ledgerID: f.ledger.uuid,
            allocations: [
                .init(
                    originalTransactionUUID: imported.uuid,
                    amountMinorUnits: imported.amountMinorUnits
                ),
            ]
        )

        #expect(throws: TransactionCSVImportError.batchHasActiveTransactionLinks) {
            try importer.undoBatch(batchUUID: batch.uuid)
        }
        #expect(!batch.isSoftDeleted)
        #expect(!imported.isSoftDeleted)
        #expect(!settlement.isSoftDeleted)
        #expect(try f.context.fetchCount(FetchDescriptor<TransactionLink>(
            predicate: #Predicate { !$0.isSoftDeleted }
        )) == 1)
    }

    @Test func 导入与整批撤销按最早时点失效转账双方快照() throws {
        let f = try makeFixture()
        let importer = TransactionCSVImporter(context: f.context)
        let snapshotService = BalanceSnapshotService(context: f.context)
        let midSnapshotAt = TransactionCSV.shortDateFormatter.date(from: "2026-01-10")!
        let lateSnapshotAt = TransactionCSV.shortDateFormatter.date(from: "2026-01-31")!
        let csv = """
        \(header)
        2026-01-05,转账,10,,现金,储蓄卡,0.10,早期
        2026-01-20,转账,20,,现金,储蓄卡,0.20,晚期
        """

        // 创建路径经 TransactionService 落库：来源与目标账户的既有晚期快照都应失效。
        try snapshotService.generateSnapshot(accountUUID: f.cash.uuid, asOf: lateSnapshotAt)
        try snapshotService.generateSnapshot(accountUUID: f.card.uuid, asOf: lateSnapshotAt)
        let batch = try importer.importTransactions(
            csv: csv, fileName: "transfers.csv",
            ledgerID: f.ledger.uuid, importedAt: importedAt
        )
        #expect(try activeSnapshotCount(f.context, accountUUID: f.cash.uuid) == 0)
        #expect(try activeSnapshotCount(f.context, accountUUID: f.card.uuid) == 0)

        // 撤销必须按批内最早 1/5 失效：1/10 与 1/31 两个检查点均应被清掉。
        for account in [f.cash, f.card] {
            try snapshotService.generateSnapshot(accountUUID: account.uuid, asOf: midSnapshotAt)
            try snapshotService.generateSnapshot(accountUUID: account.uuid, asOf: lateSnapshotAt)
        }
        try importer.undoBatch(batchUUID: batch.uuid)
        #expect(try activeSnapshotCount(f.context, accountUUID: f.cash.uuid) == 0)
        #expect(try activeSnapshotCount(f.context, accountUUID: f.card.uuid) == 0)
    }

    @Test func 非转账行带手续费行级报错() throws {
        let f = try makeFixture()
        let csv = """
        \(header)
        2026-01-01,支出,10,餐饮,现金,,1.50,支出带手续费
        2026-01-02,收入,10,,现金,,2,收入带手续费
        2026-01-03,转账,100,,现金,储蓄卡,0.50,转账带手续费合法
        """
        do {
            try TransactionCSVImporter(context: f.context).importTransactions(
                csv: csv, fileName: "a.csv", ledgerID: f.ledger.uuid, importedAt: importedAt
            )
            Issue.record("应整批失败")
        } catch let TransactionCSVImportError.invalidRows(errors) {
            #expect(errors.map(\.line) == [2, 3]) // 手续费不再被静默归零
        }
        #expect(try activeTransactionCount(f.context) == 0)
    }

    @Test func 服务层第二行失败时批次流水与快照失效统一回滚() throws {
        let f = try makeFixture()
        var childDraft = CategoryDraft()
        childDraft.name = "早餐"
        childDraft.kind = .expense
        childDraft.parentID = f.dining.uuid
        _ = try CategoryService(context: f.context).createCategory(childDraft)
        f.context.insert(Category(name: "交通", kind: .expense, sortOrder: 1))
        f.dining.isArchived = true
        try f.context.save()

        let snapshotAt = TransactionCSV.shortDateFormatter.date(from: "2026-01-31")!
        try BalanceSnapshotService(context: f.context).generateSnapshot(
            accountUUID: f.cash.uuid, asOf: snapshotAt
        )
        #expect(try activeSnapshotCount(f.context, accountUUID: f.cash.uuid) == 1)
        let csv = """
        \(header)
        2026-01-05,支出,10,交通,现金,,,第一行可落库
        2026-01-06,支出,10,早餐,现金,,,子分类自身未归档但父分类已归档
        """

        #expect(throws: TransactionServiceError.categoryArchived) {
            try TransactionCSVImporter(context: f.context).importTransactions(
                csv: csv, fileName: "stage-failure.csv",
                ledgerID: f.ledger.uuid, importedAt: self.importedAt
            )
        }
        #expect(try activeTransactionCount(f.context) == 0)
        #expect(try f.context.fetchCount(FetchDescriptor<ImportBatch>()) == 0)
        #expect(try activeSnapshotCount(f.context, accountUUID: f.cash.uuid) == 1)
    }

    @Test func 半批崩溃现场undoBatch可清理且幂等() throws {
        let f = try makeFixture()
        // 模拟"批次行已 save、流水只落了一半、transactionCount 未回填"的崩溃现场
        let batch = ImportBatch(fileName: "half.csv", importedAt: importedAt)
        batch.contentHash = TransactionCSVImporter.contentHash(of: "half")
        f.context.insert(batch)
        try f.context.save()
        var draft = TransactionDraft()
        draft.kind = .expense
        draft.amountString = "10"
        draft.occurredAt = importedAt
        draft.accountUUID = f.cash.uuid
        draft.categoryUUID = f.dining.uuid
        let tx = try TransactionService(context: f.context).recordTransaction(draft, ledgerID: f.ledger.uuid)
        tx.sourceKindRawValue = TransactionSourceKind.csvImport.rawValue
        tx.sourceID = batch.uuid
        try f.context.save()

        // 批次行先落库：崩溃后撞哈希仍可查出
        let importer = TransactionCSVImporter(context: f.context)
        #expect(try importer.existingBatch(withContentHash: batch.contentHash)?.uuid == batch.uuid)

        try importer.undoBatch(batchUUID: batch.uuid)
        #expect(try activeTransactionCount(f.context) == 0)
        #expect(batch.isSoftDeleted)

        // 幂等：重复撤销不报错、结果不变
        try importer.undoBatch(batchUUID: batch.uuid)
        #expect(try activeTransactionCount(f.context) == 0)
        #expect(batch.isSoftDeleted)
    }

    @Test func 撤销不存在的批次报错() throws {
        let f = try makeFixture()
        #expect(throws: TransactionCSVImportError.batchNotFound) {
            try TransactionCSVImporter(context: f.context).undoBatch(batchUUID: UUID())
        }
    }

    @Test func 同内容哈希可查出疑似重复导入() throws {
        let f = try makeFixture()
        let csv = header + "\n2026-01-01,支出,10,餐饮,现金,,,\n"
        let importer = TransactionCSVImporter(context: f.context)
        let hash = TransactionCSVImporter.contentHash(of: csv)
        #expect(try importer.existingBatch(withContentHash: hash) == nil)
        let batch = try importer.importTransactions(
            csv: csv, fileName: "a.csv", ledgerID: f.ledger.uuid, importedAt: importedAt
        )
        #expect(try importer.existingBatch(withContentHash: hash)?.uuid == batch.uuid)
        // 撤销后的批次不再触发重复警告
        try importer.undoBatch(batchUUID: batch.uuid)
        #expect(try importer.existingBatch(withContentHash: hash) == nil)
    }

    // MARK: - 行数上限与归档策略

    @Test func 超过字节上限时在解析前整批拒绝() throws {
        let f = try makeFixture()
        let csv = String(
            repeating: "x",
            count: TransactionCSVImporter.maxImportByteCount + 1
        )

        #expect(
            throws: TransactionCSVImportError.fileTooLarge(
                limitMiB: TransactionCSVImporter.maxImportByteCount / 1_024 / 1_024
            )
        ) {
            try TransactionCSVImporter(context: f.context).importTransactions(
                csv: csv,
                fileName: "oversized.csv",
                ledgerID: f.ledger.uuid,
                importedAt: self.importedAt
            )
        }
        #expect(try activeTransactionCount(f.context) == 0)
        #expect(try f.context.fetchCount(FetchDescriptor<ImportBatch>()) == 0)
    }

    @Test func URL读取按文件大小提前拒绝超限输入() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "CSVReadLimitTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "oversized.csv")
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(
            atOffset: UInt64(TransactionCSVImporter.maxImportByteCount + 1)
        )
        try handle.close()

        #expect(
            throws: TransactionCSVImportError.fileTooLarge(
                limitMiB: TransactionCSVImporter.maxImportByteCount / 1_024 / 1_024
            )
        ) {
            _ = try TransactionCSVImporter.readCSV(from: url)
        }
    }

    @Test func 超过行数上限整批拒绝() throws {
        let f = try makeFixture()
        let rows = String(repeating: "2026-01-01,支出,10,餐饮,现金,,,\n", count: TransactionCSVImporter.maxImportRows + 1)
        let csv = header + "\n" + rows + "\"未闭合"
        #expect(throws: TransactionCSVImportError.tooManyRows(limit: TransactionCSVImporter.maxImportRows)) {
            try TransactionCSVImporter(context: f.context).importTransactions(
                csv: csv, fileName: "big.csv", ledgerID: f.ledger.uuid, importedAt: importedAt
            )
        }
        #expect(try activeTransactionCount(f.context) == 0)
    }

    @Test func 恰达上限通过行数检查() throws {
        let f = try makeFixture()
        // 恰 10_000 行且末行金额非法：抛 invalidRows 而非 tooManyRows，
        // 证明上限判定放行边界值，又不用真落库 10_000 笔（逐笔 save 过慢）
        var rows = String(repeating: "2026-01-01,支出,10,餐饮,现金,,,\n", count: TransactionCSVImporter.maxImportRows - 1)
        rows += "2026-01-01,支出,abc,餐饮,现金,,,\n"
        let csv = header + "\n" + rows
        do {
            try TransactionCSVImporter(context: f.context).importTransactions(
                csv: csv, fileName: "big.csv", ledgerID: f.ledger.uuid, importedAt: importedAt
            )
            Issue.record("应因末行非法整批失败")
        } catch let TransactionCSVImportError.invalidRows(errors) {
            #expect(errors.map(\.line) == [TransactionCSVImporter.maxImportRows + 1])
        } catch {
            Issue.record("上限边界值不应触发 tooManyRows：\(error)")
        }
    }

    @Test func 归档账户行级报错() throws {
        let f = try makeFixture()
        f.card.isArchived = true
        try f.context.save()
        let csv = """
        \(header)
        2026-01-01,支出,10,餐饮,储蓄卡,,,归档账户支出
        2026-01-02,转账,10,,现金,储蓄卡,,转入归档账户
        """
        do {
            try TransactionCSVImporter(context: f.context).importTransactions(
                csv: csv, fileName: "a.csv", ledgerID: f.ledger.uuid, importedAt: importedAt
            )
            Issue.record("应整批失败")
        } catch let TransactionCSVImportError.invalidRows(errors) {
            #expect(errors.map(\.line) == [2, 3])
            #expect(errors[0].message == TransactionCSVImportError.accountArchived("储蓄卡").localizedDescription)
        }
        #expect(try activeTransactionCount(f.context) == 0)
    }

    @Test func 不可记账账户作为来源或转入方均在预校验阶段按行拒绝() throws {
        let f = try makeFixture()
        f.card.isSelectableForRecord = false
        try f.context.save()
        let csv = """
        \(header)
        2026-01-01,支出,10,餐饮,储蓄卡,,,来源账户不可记账
        2026-01-02,转账,10,,现金,储蓄卡,,转入账户不可记账
        """

        do {
            try TransactionCSVImporter(context: f.context).importTransactions(
                csv: csv, fileName: "not-selectable.csv",
                ledgerID: f.ledger.uuid, importedAt: importedAt
            )
            Issue.record("不可记账账户应在预校验阶段整批拒绝")
        } catch let TransactionCSVImportError.invalidRows(errors) {
            #expect(errors.map(\.line) == [2, 3])
            #expect(errors.allSatisfy {
                $0.message == TransactionCSVImportError.accountNotSelectable("储蓄卡").localizedDescription
            })
        }
        #expect(try activeTransactionCount(f.context) == 0)
        #expect(try f.context.fetchCount(FetchDescriptor<ImportBatch>()) == 0)
    }
}
