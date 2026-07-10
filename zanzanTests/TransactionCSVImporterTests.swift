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

    private let header = "日期,类型,金额,分类,账户,转入账户,手续费,备注"
    private let importedAt = TransactionCSV.dateFormatter.date(from: "2026-02-01 10:00:00")!

    private func activeTransactionCount(_ context: ModelContext) throws -> Int {
        try context.fetchCount(FetchDescriptor<Transaction>(predicate: #Predicate { !$0.isSoftDeleted }))
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
}
