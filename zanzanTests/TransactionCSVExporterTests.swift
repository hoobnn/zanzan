import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct TransactionCSVExporterTests {
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

    private func date(_ string: String) -> Date {
        TransactionCSV.dateFormatter.date(from: string)!
    }

    @discardableResult
    private func recordExpense(
        _ f: Fixture, amount: String, note: String = "", occurredAt: Date
    ) throws -> Transaction {
        var draft = TransactionDraft()
        draft.kind = .expense
        draft.amountString = amount
        draft.occurredAt = occurredAt
        draft.note = note
        draft.accountUUID = f.cash.uuid
        draft.categoryUUID = f.dining.uuid
        return try TransactionService(context: f.context).recordTransaction(draft, ledgerID: f.ledger.uuid)
    }

    @Test func 导出表头与基本字段() throws {
        let f = try makeFixture()
        try recordExpense(f, amount: "25.50", note: "午饭", occurredAt: date("2026-01-05 12:30:00"))
        let csv = try TransactionCSVExporter(context: f.context)
            .exportCSV(ledgerID: f.ledger.uuid, from: date("2026-01-01 00:00:00"), to: date("2026-12-31 23:59:59"))
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines[0] == "日期,类型,金额,分类,账户,转入账户,手续费,备注")
        #expect(lines[1] == "2026-01-05 12:30:00,支出,25.5,餐饮,现金,,,午饭")
    }

    @Test func 特殊字符按RFC4180转义() throws {
        let f = try makeFixture()
        let note = "含,逗号 与\"引号\"\n还有换行"
        try recordExpense(f, amount: "1", note: note, occurredAt: date("2026-01-05 12:30:00"))
        let csv = try TransactionCSVExporter(context: f.context)
            .exportCSV(ledgerID: f.ledger.uuid, from: date("2026-01-01 00:00:00"), to: date("2026-12-31 23:59:59"))
        #expect(csv.contains("\"含,逗号 与\"\"引号\"\"\n还有换行\""))
        // 解析回来逐字等值
        let records = try TransactionCSV.parse(csv)
        #expect(records.count == 2)
        #expect(records[1][7] == note)
    }

    @Test func 软删流水不导出且范围外过滤() throws {
        let f = try makeFixture()
        let inRange = try recordExpense(f, amount: "1", occurredAt: date("2026-01-05 12:00:00"))
        try recordExpense(f, amount: "2", occurredAt: date("2027-01-01 00:00:00")) // 范围外
        let deleted = try recordExpense(f, amount: "3", occurredAt: date("2026-01-06 12:00:00"))
        try TransactionService(context: f.context).softDeleteTransaction(uuid: deleted.uuid)
        let csv = try TransactionCSVExporter(context: f.context)
            .exportCSV(ledgerID: f.ledger.uuid, from: date("2026-01-01 00:00:00"), to: date("2026-12-31 23:59:59"))
        let records = try TransactionCSV.parse(csv)
        #expect(records.count == 2) // 表头 + 唯一在范围内的活跃流水
        #expect(records[1][2] == MoneyAmount.decimalString(fromMinorUnits: inRange.amountMinorUnits))
    }

    @Test func 转账含手续费导出() throws {
        let f = try makeFixture()
        var draft = TransactionDraft()
        draft.kind = .transfer
        draft.amountString = "100"
        draft.feeString = "0.50"
        draft.occurredAt = date("2026-01-05 09:00:00")
        draft.accountUUID = f.cash.uuid
        draft.targetAccountUUID = f.card.uuid
        try TransactionService(context: f.context).recordTransaction(draft, ledgerID: f.ledger.uuid)
        let csv = try TransactionCSVExporter(context: f.context)
            .exportCSV(ledgerID: f.ledger.uuid, from: date("2026-01-01 00:00:00"), to: date("2026-12-31 23:59:59"))
        let records = try TransactionCSV.parse(csv)
        #expect(records[1] == ["2026-01-05 09:00:00", "转账", "100", "", "现金", "储蓄卡", "0.5", ""])
    }

    @Test func 导出再导入往返等值() throws {
        let f = try makeFixture()
        let note = "转义,往返\"测试\""
        try recordExpense(f, amount: "1234.56", note: note, occurredAt: date("2026-01-05 12:30:00"))
        var transfer = TransactionDraft()
        transfer.kind = .transfer
        transfer.amountString = "88.88"
        transfer.feeString = "0.10"
        transfer.occurredAt = date("2026-01-06 08:00:00")
        transfer.accountUUID = f.cash.uuid
        transfer.targetAccountUUID = f.card.uuid
        try TransactionService(context: f.context).recordTransaction(transfer, ledgerID: f.ledger.uuid)

        let csv = try TransactionCSVExporter(context: f.context)
            .exportCSV(ledgerID: f.ledger.uuid, from: date("2026-01-01 00:00:00"), to: date("2026-12-31 23:59:59"))
        let batch = try TransactionCSVImporter(context: f.context).importTransactions(
            csv: csv, fileName: "roundtrip.csv", ledgerID: f.ledger.uuid, importedAt: date("2026-02-01 00:00:00")
        )

        let batchUUID = batch.uuid
        let imported = try f.context.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.sourceID == batchUUID },
            sortBy: [SortDescriptor(\.occurredAt, order: .forward)]
        ))
        #expect(imported.count == 2)
        #expect(imported[0].kind == .expense)
        #expect(imported[0].amountMinorUnits == 123_456)
        #expect(imported[0].note == note)
        #expect(imported[0].occurredAt == date("2026-01-05 12:30:00"))
        #expect(imported[0].category?.uuid == f.dining.uuid)
        #expect(imported[1].kind == .transfer)
        #expect(imported[1].amountMinorUnits == 8_888)
        #expect(imported[1].feeMinorUnits == 10)
        #expect(imported[1].targetAccount?.uuid == f.card.uuid)
    }
}
