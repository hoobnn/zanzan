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

    /// 直接落库一笔支出流水（绕开 Draft，聚焦报销逻辑）；
    /// 外币场景直接对模型赋 currencyCode/fxRateToBase（不依赖在途 Draft 新字段）
    @discardableResult
    private func makeExpense(
        _ f: Fixture, amount: Int, account: Account? = nil, fxRateToBase: Decimal? = nil
    ) throws -> Transaction {
        let tx = Transaction(kind: .expense, amountMinorUnits: amount, occurredAt: .now, ledgerID: f.ledger.uuid)
        let account = account ?? f.cash
        tx.account = account
        tx.category = f.dining
        tx.currencyCode = account.currencyCode
        tx.fxRateToBase = fxRateToBase
        f.context.insert(tx)
        try f.context.save()
        return tx
    }

    /// 建一个外币账户（默认 USD）
    private func makeForeignAccount(_ f: Fixture, currencyCode: String = "USD") throws -> Account {
        let account = Account(name: "外币卡\(currencyCode)", kind: .fund)
        account.currencyCode = currencyCode
        f.context.insert(account)
        try f.context.save()
        return account
    }

    /// 登记到账的便捷入口（默认到账 CNY 现金户、默认落公共账本）
    @discardableResult
    private func settle(
        _ f: Fixture,
        kind: TransactionLinkKind = .reimbursement,
        amount: Int,
        account: Account? = nil,
        ledgerID: UUID? = nil,
        allocations: [(Transaction, Int)]
    ) throws -> Transaction {
        try f.service.recordSettlement(
            kind: kind,
            amountMinorUnits: amount,
            occurredAt: .now,
            accountUUID: (account ?? f.cash).uuid,
            ledgerID: ledgerID ?? f.ledger.uuid,
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

    // MARK: - 跨币种报销（§5.5 容差近似比较 + §5.4 到账单汇率必填）

    @Test func 跨币种报销容差内通过() throws {
        let f = try makeFixture()
        let usd = try makeForeignAccount(f)
        // 垫付 $100（汇率 7.2 → 折 ¥720），本位币到账 ¥715：
        // Σ 折算分摊 72_000 ≤ 71_500 × 1.01 = 72_215，容差内放行
        let tx = try makeExpense(f, amount: 10_000, account: usd, fxRateToBase: Decimal(string: "7.2")!)
        try f.service.markAwaitingReimbursement(transactionUUID: tx.uuid)
        let settlement = try settle(f, amount: 71_500, allocations: [(tx, 10_000)])

        #expect(tx.reimbursementStatus == .settled) // 原单侧按原单币种精确覆盖：10_000 ≥ 10_000
        #expect(settlement.currencyCode == "CNY")
        #expect(settlement.fxRateToBase == nil) // 本位币到账恒 nil
        let link = try #require(try activeLinks(f).first)
        #expect(link.amountMinorUnits == 10_000) // 分摊金额以原单币种（USD 分）计
    }

    @Test func 跨币种报销超容差拒绝() throws {
        let f = try makeFixture()
        let usd = try makeForeignAccount(f)
        // Σ 折算分摊 72_000 > 70_000 × 1.01 = 70_700，超容差阻断
        let tx = try makeExpense(f, amount: 10_000, account: usd, fxRateToBase: Decimal(string: "7.2")!)
        try f.service.markAwaitingReimbursement(transactionUUID: tx.uuid)
        #expect(throws: ReimbursementServiceError.self) {
            try self.settle(f, amount: 70_000, allocations: [(tx, 10_000)])
        }
    }

    @Test func 同币种精确比较不吃容差() throws {
        let f = try makeFixture()
        // 全部同币种（CNY）走精确整数比较：6_000 > 5_999 即拒，
        // 若误走 1% 容差路径（5_999 × 1.01 ≈ 6_059）会放行——回归护栏
        let tx = try makeExpense(f, amount: 10_000)
        try f.service.markAwaitingReimbursement(transactionUUID: tx.uuid)
        #expect(throws: ReimbursementServiceError.self) {
            try self.settle(f, amount: 5_999, allocations: [(tx, 6_000)])
        }
    }

    @Test func 跨币种原单侧超额仍精确阻断() throws {
        let f = try makeFixture()
        let usd = try makeForeignAccount(f)
        // 原单侧「Σ 分摊 ≤ 原单金额」在原单币种内精确比较，不受容差影响：
        // 分摊 10_050 > 原单 10_000（USD 分），虽在 1% 容差内也必须拒
        let tx = try makeExpense(f, amount: 10_000, account: usd, fxRateToBase: Decimal(string: "7.2")!)
        try f.service.markAwaitingReimbursement(transactionUUID: tx.uuid)
        #expect(throws: ReimbursementServiceError.self) {
            try self.settle(f, amount: 100_000, allocations: [(tx, 10_050)])
        }
    }

    @Test func 外币到账账户无汇率快照阻断() throws {
        let f = try makeFixture()
        let usd = try makeForeignAccount(f)
        let tx = try makeExpense(f, amount: 10_000) // CNY 垫付
        try f.service.markAwaitingReimbursement(transactionUUID: tx.uuid)
        // 全库无 USD 汇率快照，FxRateProvider 预填不到 → §5.4 必填规则阻断
        #expect(throws: ReimbursementServiceError.self) {
            try self.settle(f, amount: 10_000, account: usd, allocations: [(tx, 10_000)])
        }
    }

    @Test func 外币到账单汇率经快照预填() throws {
        let f = try makeFixture()
        let usd = try makeForeignAccount(f)
        let rate = Decimal(string: "7.2")!
        // 垫付单本身即 USD 最近汇率快照；同为 USD 的到账走精确比较
        let tx = try makeExpense(f, amount: 10_000, account: usd, fxRateToBase: rate)
        try f.service.markAwaitingReimbursement(transactionUUID: tx.uuid)
        let settlement = try settle(f, amount: 10_000, account: usd, allocations: [(tx, 10_000)])

        #expect(settlement.currencyCode == "USD")
        #expect(settlement.fxRateToBase == rate) // 经 FxRateProvider 最近快照预填
        #expect(tx.reimbursementStatus == .settled)
    }

    @Test func 外币原单缺汇率按1比1兜底() throws {
        let f = try makeFixture()
        let usd = try makeForeignAccount(f)
        // 历史坏数据：外币原单无 fxRateToBase → 折算按 1:1 兜底，
        // 折算分摊 10_000 ≤ 10_000 × 1.01 通过
        let tx = try makeExpense(f, amount: 10_000, account: usd, fxRateToBase: nil)
        try f.service.markAwaitingReimbursement(transactionUUID: tx.uuid)
        let settlement = try settle(f, amount: 10_000, allocations: [(tx, 10_000)])
        #expect(settlement.settlementKind == .reimbursement)
        #expect(tx.reimbursementStatus == .settled)
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

    // MARK: - 恢复到账单（§4 撤销恢复按相反方向执行）

    @Test func 恢复到账单级联恢复并回到settled() throws {
        let f = try makeFixture()
        let tx = try makeExpense(f, amount: 10_000)
        try f.service.markAwaitingReimbursement(transactionUUID: tx.uuid)
        let settlement = try settle(f, amount: 10_000, allocations: [(tx, 10_000)])
        try f.service.removeSettlement(transactionUUID: settlement.uuid)
        #expect(tx.reimbursementStatus == .waiting)

        try f.service.restoreSettlement(transactionUUID: settlement.uuid)
        #expect(!settlement.isSoftDeleted)
        #expect(settlement.settlementKind == .reimbursement) // 标记按关联行重算
        let links = try activeLinks(f)
        #expect(links.count == 1) // 级联软删的关联行随主实体一并恢复
        #expect(links.first?.amountMinorUnits == 10_000)
        #expect(tx.reimbursementStatus == .settled) // waiting → settled 正向重算
    }

    @Test func 恢复部分报销到账单原单回到waiting() throws {
        let f = try makeFixture()
        let tx = try makeExpense(f, amount: 10_000)
        try f.service.markAwaitingReimbursement(transactionUUID: tx.uuid)
        let settlement = try settle(f, amount: 6_000, allocations: [(tx, 6_000)])
        try f.service.removeSettlement(transactionUUID: settlement.uuid)

        try f.service.restoreSettlement(transactionUUID: settlement.uuid)
        #expect(tx.reimbursementStatus == .waiting) // 部分覆盖恢复后仍 waiting
        #expect(try activeLinks(f).count == 1)
    }

    @Test func 恢复致原单超额分摊被阻断() throws {
        let f = try makeFixture()
        let tx = try makeExpense(f, amount: 10_000)
        try f.service.markAwaitingReimbursement(transactionUUID: tx.uuid)
        let old = try settle(f, amount: 6_000, allocations: [(tx, 6_000)])
        try f.service.removeSettlement(transactionUUID: old.uuid)
        try settle(f, amount: 10_000, allocations: [(tx, 10_000)]) // 软删期间另记全额到账
        #expect(throws: ReimbursementServiceError.self) {
            try f.service.restoreSettlement(transactionUUID: old.uuid) // 6000 + 10000 > 10000
        }
        #expect(old.isSoftDeleted) // 阻断时不落任何改动
    }

    @Test func 活跃流水不可按到账单恢复() throws {
        let f = try makeFixture()
        let tx = try makeExpense(f, amount: 10_000)
        try f.service.markAwaitingReimbursement(transactionUUID: tx.uuid)
        let settlement = try settle(f, amount: 10_000, allocations: [(tx, 10_000)])
        #expect(throws: ReimbursementServiceError.self) {
            try f.service.restoreSettlement(transactionUUID: settlement.uuid) // 未被软删
        }
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

    @Test func 退款欠分摊被拒全额通过() throws {
        let f = try makeFixture()
        let tx = try makeExpense(f, amount: 10_000)
        // R4-M2：Σ 分摊 2_000 < 到账 3_000，差额会在统计里凭空消失 → 拒
        #expect(throws: ReimbursementServiceError.self) {
            try self.settle(f, kind: .refund, amount: 3_000, allocations: [(tx, 2_000)])
        }
        #expect(try activeLinks(f).isEmpty)
        // 全额分摊通过；报销场景仍允许欠分摊（部分报销，文档明文）
        try settle(f, kind: .refund, amount: 3_000, allocations: [(tx, 3_000)])
        #expect(try activeLinks(f).count == 1)
    }

    @Test func 跨账本登记到账被拒() throws {
        let f = try makeFixture()
        let other = try LedgerService(context: f.context).createLedger(LedgerDraft(name: "旅行"))
        let tx = try makeExpense(f, amount: 10_000) // 原单落公共账本
        // R4-L2：到账单记到另一账本会把退款冲减记错账本 → 拒
        #expect(throws: ReimbursementServiceError.self) {
            try self.settle(f, kind: .refund, amount: 3_000, ledgerID: other.uuid, allocations: [(tx, 3_000)])
        }
    }

    // MARK: - 前向兼容（R3-L1）

    @Test func 未知报销状态串不被覆写() throws {
        let f = try makeFixture()
        let tx = try makeExpense(f, amount: 10_000)
        tx.reimbursementStatusRawValue = "futureStatus" // 高版本写入的未知状态
        try f.context.save()
        #expect(throws: ReimbursementServiceError.self) {
            try f.service.markAwaitingReimbursement(transactionUUID: tx.uuid)
        }
        #expect(tx.reimbursementStatusRawValue == "futureStatus") // 不被覆写成 waiting
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
