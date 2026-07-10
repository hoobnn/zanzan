import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct ReimbursementServiceTests {
    /// 建好账本/账户/分类的公共夹具
    private struct Fixture {
        let context: ModelContext
        let ledger: Ledger
        let cash: Account
        let dining: Category // expense
        @MainActor var service: ReimbursementService { ReimbursementService(context: context) }
    }

    private func makeFixture() throws -> Fixture {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let ledger = try LedgerService(context: context).createLedger(LedgerDraft(name: "日常"))
        let cash = Account(name: "现金", kind: .fund)
        let dining = Category(name: "餐饮", kind: .expense, sortOrder: 0)
        context.insert(cash)
        context.insert(dining)
        try context.save()
        return Fixture(context: context, ledger: ledger, cash: cash, dining: dining)
    }

    /// 直接落库一笔支出流水（绕开 Draft，聚焦报销逻辑）
    @discardableResult
    private func makeExpense(_ f: Fixture, amount: Int) throws -> Transaction {
        let tx = Transaction(kind: .expense, amountMinorUnits: amount, occurredAt: .now, ledgerID: f.ledger.uuid)
        tx.account = f.cash
        tx.category = f.dining
        f.context.insert(tx)
        try f.context.save()
        return tx
    }

    /// 登记到账的便捷入口
    @discardableResult
    private func settle(
        _ f: Fixture,
        kind: TransactionLinkKind = .reimbursement,
        amount: Int,
        allocations: [(Transaction, Int)]
    ) throws -> Transaction {
        try f.service.recordSettlement(
            kind: kind,
            amountMinorUnits: amount,
            occurredAt: .now,
            accountUUID: f.cash.uuid,
            ledgerID: f.ledger.uuid,
            allocations: allocations.map {
                ReimbursementService.Allocation(originalTransactionUUID: $0.0.uuid, amountMinorUnits: $0.1)
            }
        )
    }

    private func activeLinks(_ f: Fixture) throws -> [TransactionLink] {
        try f.context.fetch(FetchDescriptor<TransactionLink>(predicate: #Predicate { !$0.isSoftDeleted }))
    }

    // MARK: - 垫付标记

    @Test func 标记垫付置waiting() throws {
        let f = try makeFixture()
        let tx = try makeExpense(f, amount: 10_000)
        try f.service.markAwaitingReimbursement(transactionUUID: tx.uuid)
        #expect(tx.reimbursementStatus == .waiting)
        #expect(tx.kind == .expense) // kind 终生不改写
    }

    @Test func 非支出流水不可标记垫付() throws {
        let f = try makeFixture()
        let income = Transaction(kind: .income, amountMinorUnits: 1_000, occurredAt: .now, ledgerID: f.ledger.uuid)
        f.context.insert(income)
        try f.context.save()
        #expect(throws: ReimbursementServiceError.self) {
            try f.service.markAwaitingReimbursement(transactionUUID: income.uuid)
        }
    }

    @Test func 重复标记被拒() throws {
        let f = try makeFixture()
        let tx = try makeExpense(f, amount: 10_000)
        try f.service.markAwaitingReimbursement(transactionUUID: tx.uuid)
        #expect(throws: ReimbursementServiceError.self) {
            try f.service.markAwaitingReimbursement(transactionUUID: tx.uuid)
        }
    }

    @Test func 取消标记回到非报销态() throws {
        let f = try makeFixture()
        let tx = try makeExpense(f, amount: 10_000)
        try f.service.markAwaitingReimbursement(transactionUUID: tx.uuid)
        try f.service.unmarkReimbursement(transactionUUID: tx.uuid)
        #expect(tx.reimbursementStatus == nil)
        #expect(tx.reimbursementStatusRawValue.isEmpty)
    }

    @Test func 已有分摊不可取消标记() throws {
        let f = try makeFixture()
        let tx = try makeExpense(f, amount: 10_000)
        try f.service.markAwaitingReimbursement(transactionUUID: tx.uuid)
        try settle(f, amount: 4_000, allocations: [(tx, 4_000)])
        #expect(throws: ReimbursementServiceError.self) {
            try f.service.unmarkReimbursement(transactionUUID: tx.uuid)
        }
    }

    @Test func 手动结案置settled() throws {
        let f = try makeFixture()
        let tx = try makeExpense(f, amount: 10_000)
        try f.service.markAwaitingReimbursement(transactionUUID: tx.uuid)
        try settle(f, amount: 6_000, allocations: [(tx, 6_000)]) // 实报少于垫付
        #expect(tx.reimbursementStatus == .waiting)
        try f.service.settleManually(transactionUUID: tx.uuid)
        #expect(tx.reimbursementStatus == .settled)
    }

    // MARK: - 登记报销打款

    @Test func 全额报销建关联并置settled() throws {
        let f = try makeFixture()
        let tx = try makeExpense(f, amount: 10_000)
        try f.service.markAwaitingReimbursement(transactionUUID: tx.uuid)
        let settlement = try settle(f, amount: 10_000, allocations: [(tx, 10_000)])

        #expect(settlement.kind == .income)
        #expect(settlement.settlementKind == .reimbursement)
        #expect(settlement.account?.uuid == f.cash.uuid)
        #expect(settlement.category == nil) // 到账单不挂分类
        #expect(tx.reimbursementStatus == .settled)
        let links = try activeLinks(f)
        #expect(links.count == 1)
        #expect(links.first?.originalTransactionID == tx.uuid)
        #expect(links.first?.settlementTransactionID == settlement.uuid)
        #expect(links.first?.amountMinorUnits == 10_000)
        #expect(links.first?.kind == .reimbursement)
    }

    @Test func 部分报销保持waiting() throws {
        let f = try makeFixture()
        let tx = try makeExpense(f, amount: 10_000)
        try f.service.markAwaitingReimbursement(transactionUUID: tx.uuid)
        try settle(f, amount: 6_000, allocations: [(tx, 6_000)])
        #expect(tx.reimbursementStatus == .waiting) // 部分报销中 = waiting 且已报销额 > 0（派生态）
    }

    @Test func 合并打款覆盖多张垫付单() throws {
        let f = try makeFixture()
        let a = try makeExpense(f, amount: 3_000)
        let b = try makeExpense(f, amount: 7_000)
        try f.service.markAwaitingReimbursement(transactionUUID: a.uuid)
        try f.service.markAwaitingReimbursement(transactionUUID: b.uuid)
        try settle(f, amount: 10_000, allocations: [(a, 3_000), (b, 7_000)])
        #expect(a.reimbursementStatus == .settled)
        #expect(b.reimbursementStatus == .settled)
        #expect(try activeLinks(f).count == 2)
    }

    @Test func 多次报销累计推进settled() throws {
        let f = try makeFixture()
        let tx = try makeExpense(f, amount: 10_000)
        try f.service.markAwaitingReimbursement(transactionUUID: tx.uuid)
        try settle(f, amount: 6_000, allocations: [(tx, 6_000)])
        #expect(tx.reimbursementStatus == .waiting)
        try settle(f, amount: 4_000, allocations: [(tx, 4_000)])
        #expect(tx.reimbursementStatus == .settled)
    }

    @Test func 累计分摊超垫付额阻断() throws {
        let f = try makeFixture()
        let tx = try makeExpense(f, amount: 10_000)
        try f.service.markAwaitingReimbursement(transactionUUID: tx.uuid)
        try settle(f, amount: 6_000, allocations: [(tx, 6_000)])
        #expect(throws: ReimbursementServiceError.self) {
            try self.settle(f, amount: 5_000, allocations: [(tx, 5_000)]) // 6000 + 5000 > 10000
        }
    }

    @Test func 分摊合计超到账金额阻断() throws {
        let f = try makeFixture()
        let tx = try makeExpense(f, amount: 10_000)
        try f.service.markAwaitingReimbursement(transactionUUID: tx.uuid)
        #expect(throws: ReimbursementServiceError.self) {
            try self.settle(f, amount: 5_000, allocations: [(tx, 6_000)])
        }
    }

    @Test func 未标记垫付不可登记报销() throws {
        let f = try makeFixture()
        let tx = try makeExpense(f, amount: 10_000)
        #expect(throws: ReimbursementServiceError.self) {
            try self.settle(f, amount: 10_000, allocations: [(tx, 10_000)])
        }
    }

    @Test func 分摊明细非法被拒() throws {
        let f = try makeFixture()
        let tx = try makeExpense(f, amount: 10_000)
        try f.service.markAwaitingReimbursement(transactionUUID: tx.uuid)
        #expect(throws: ReimbursementServiceError.self) {
            try self.settle(f, amount: 10_000, allocations: []) // 空分摊
        }
        #expect(throws: ReimbursementServiceError.self) {
            try self.settle(f, amount: 10_000, allocations: [(tx, 0)]) // 非正金额
        }
        #expect(throws: ReimbursementServiceError.self) {
            try self.settle(f, amount: 10_000, allocations: [(tx, 4_000), (tx, 4_000)]) // 重复原单
        }
    }

    // MARK: - 解除关联与状态回退

    @Test func 软删到账单级联回退waiting() throws {
        let f = try makeFixture()
        let tx = try makeExpense(f, amount: 10_000)
        try f.service.markAwaitingReimbursement(transactionUUID: tx.uuid)
        let settlement = try settle(f, amount: 10_000, allocations: [(tx, 10_000)])
        #expect(tx.reimbursementStatus == .settled)

        try f.service.removeSettlement(transactionUUID: settlement.uuid)
        #expect(settlement.isSoftDeleted)
        #expect(try activeLinks(f).isEmpty) // 级联软删关联行
        #expect(tx.reimbursementStatus == .waiting) // settled → waiting 回退
    }

    @Test func 解除单条关联回退并重算到账单标记() throws {
        let f = try makeFixture()
        let tx = try makeExpense(f, amount: 10_000)
        try f.service.markAwaitingReimbursement(transactionUUID: tx.uuid)
        let settlement = try settle(f, amount: 10_000, allocations: [(tx, 10_000)])
        let link = try #require(try activeLinks(f).first)

        try f.service.removeLink(linkUUID: link.uuid)
        #expect(link.isSoftDeleted)
        #expect(tx.reimbursementStatus == .waiting)
        #expect(settlement.settlementKind == nil) // 关联清零 → 冗余标记重算为空
        #expect(!settlement.isSoftDeleted) // 到账单本身保留（回落为普通收入）
    }

    @Test func 普通流水不可按到账单删除() throws {
        let f = try makeFixture()
        let tx = try makeExpense(f, amount: 10_000)
        #expect(throws: ReimbursementServiceError.self) {
            try f.service.removeSettlement(transactionUUID: tx.uuid)
        }
    }

    // MARK: - 退款

    @Test func 退款登记建关联且原单无需标记() throws {
        let f = try makeFixture()
        let tx = try makeExpense(f, amount: 10_000)
        let refund = try settle(f, kind: .refund, amount: 3_000, allocations: [(tx, 3_000)])

        #expect(refund.kind == .income)
        #expect(refund.settlementKind == .refund)
        #expect(tx.reimbursementStatus == nil) // 退款不参与 waiting/settled 状态机
        let links = try activeLinks(f)
        #expect(links.first?.kind == .refund)
        #expect(links.first?.amountMinorUnits == 3_000)
    }

    @Test func 退款累计不超原单金额() throws {
        let f = try makeFixture()
        let tx = try makeExpense(f, amount: 10_000)
        try settle(f, kind: .refund, amount: 8_000, allocations: [(tx, 8_000)])
        #expect(throws: ReimbursementServiceError.self) {
            try self.settle(f, kind: .refund, amount: 3_000, allocations: [(tx, 3_000)])
        }
    }

    // MARK: - 月度统计口径（联动 MonthlyStatsProvider）

    @Test func 报销打款不计收入垫付仍计支出() throws {
        let f = try makeFixture()
        let tx = try makeExpense(f, amount: 10_000)
        try f.service.markAwaitingReimbursement(transactionUUID: tx.uuid)
        try settle(f, amount: 10_000, allocations: [(tx, 10_000)])

        let now = Calendar.current.dateComponents([.year, .month], from: .now)
        let stats = try MonthlyStatsProvider(context: f.context)
            .stats(ledgerID: f.ledger.uuid, year: now.year!, month: now.month!)
        #expect(stats.incomeTotalMinorUnits == 0) // 报销到账不计收入
        #expect(stats.expenseTotalMinorUnits == 10_000) // 垫付支出照常计支出
    }

    @Test func 退款冲减支出总额与对应分类() throws {
        let f = try makeFixture()
        let tx = try makeExpense(f, amount: 10_000)
        try settle(f, kind: .refund, amount: 3_000, allocations: [(tx, 3_000)])

        let now = Calendar.current.dateComponents([.year, .month], from: .now)
        let stats = try MonthlyStatsProvider(context: f.context)
            .stats(ledgerID: f.ledger.uuid, year: now.year!, month: now.month!)
        #expect(stats.incomeTotalMinorUnits == 0) // 退款到账不计收入
        #expect(stats.expenseTotalMinorUnits == 7_000) // 冲减支出总额
        let dining = try #require(stats.expenseRanking.first { $0.category.uuid == f.dining.uuid })
        #expect(dining.totalMinorUnits == 7_000) // 冲减对应分类
    }
}
