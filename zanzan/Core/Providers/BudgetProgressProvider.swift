import Foundation
import SwiftData

/// 单条预算的执行进度（生效行 + 已用额，余额/比例现算不落库）。
struct BudgetProgress {
    /// 生效行：优先当月实体行，无则回落模板行（设计文档 5.7）
    let budget: Budget
    let usedMinorUnits: Int
    let remainingMinorUnits: Int

    init(budget: Budget, usedMinorUnits: Int) throws {
        self.budget = budget
        self.usedMinorUnits = usedMinorUnits
        remainingMinorUnits = try MoneyArithmetic.subtract(
            budget.amountMinorUnits, usedMinorUnits
        )
    }
    /// 已用比例（>1 表示超支）；额度非正防御为 0
    var usedFraction: Double {
        budget.amountMinorUnits > 0 ? Double(usedMinorUnits) / Double(budget.amountMinorUnits) : 0
    }
}

/// 某账本某月的预算全景。
struct MonthlyBudgetProgress {
    /// 总预算（categoryID == nil）；未设置则为 nil
    let total: BudgetProgress?
    /// 分类预算，按已用额降序
    let categories: [BudgetProgress]
}

/// 预算进度只读投影（设计文档 5.7）：预算金额一律本位币计（§4 折算口径③），
/// 已用额走预算专用金额口径，并按流水自身汇率快照折本位币。
/// 总预算已用 = 当月支出合计（fee 恒为流出一并计入）；
/// 分类预算已用 = 该一级分类含全部子类的支出 rollup（fee 无分类归属，不进分类口径）。
/// 退款到账按 RefundAdjustmentResolver 的 link 明细冲减，总额与分类同口径；
/// 原单不计预算的退款不冲减（对称：没计入的不冲）。跨月退款打负属口径自然结果，与月度统计一致。
/// 剔除软删流水、isExcludedFromBudget 与已报销（settled）支出。
struct BudgetProgressProvider {
    let context: ModelContext

    func progress(
        ledgerID: UUID, year: Int, month: Int, calendar: Calendar = .current
    ) throws -> MonthlyBudgetProgress {
        guard
            (1...12).contains(month),
            let monthStart = calendar.date(from: DateComponents(year: year, month: month)),
            let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: monthStart)
        else { throw BudgetProgressError.invalidMonth }

        let budgets = try effectiveBudgets(ledgerID: ledgerID, year: year, month: month)
        guard !budgets.isEmpty else { return MonthlyBudgetProgress(total: nil, categories: []) }

        let settledRaw = ReimbursementStatus.settled.rawValue
        let id: UUID? = ledgerID
        let transactions = try context.fetch(
            FetchDescriptor<Transaction>(predicate: #Predicate {
                !$0.isSoftDeleted && $0.ledgerID == id
                    && $0.occurredAt >= monthStart && $0.occurredAt < nextMonthStart
                    && !$0.isExcludedFromBudget
                    && $0.reimbursementStatusRawValue != settledRaw
            })
        )

        // 退款冲减按 link 明细走共享助手（与月度统计分类口径一致）；
        // 对称性：原单不计预算的（本就没计入已用）退款不得冲减——总额与分类都不冲
        let refunds = try RefundAdjustmentResolver.adjustments(in: transactions, context: context)
            .filter { !$0.isOriginalExcludedFromBudget }

        // 总预算：退款到账的 amount 冲减按上面 link 明细计（总额与分类同口径），
        // 到账单只保留 fee（fee 恒为流出）；其余流水走预算专用口径。
        // isExcludedFromStats 与预算开关彼此独立，绝不能复用 statsExpense/statsFee。
        let totalUsed = try MoneyArithmetic.add(
            MoneyArithmetic.sum(transactions.map { try budgetExpenseMinorUnits(of: $0) }),
            MoneyArithmetic.sum(refunds.map(\.amountMinorUnits))
        )

        var usedByParent: [UUID: Int] = [:]
        for tx in transactions where tx.kind == .expense {
            // fee 无分类归属，不进分类预算；分类只累计折算后的支出本金。
            let value = try budgetBaseMinorUnits(tx.amountMinorUnits, of: tx)
            guard value > 0, let category = tx.category else { continue }
            let parentID = category.parentID ?? category.uuid
            usedByParent[parentID] = try MoneyArithmetic.add(
                usedByParent[parentID, default: 0], value
            )
        }
        for refund in refunds {
            guard let category = refund.category else { continue } // 原单无分类：只冲总额
            let parentID = category.parentID ?? category.uuid
            usedByParent[parentID] = try MoneyArithmetic.add(
                usedByParent[parentID, default: 0], refund.amountMinorUnits
            )
        }

        var total: BudgetProgress?
        var categories: [BudgetProgress] = []
        for budget in budgets {
            if let categoryID = budget.categoryID {
                categories.append(
                    try BudgetProgress(
                        budget: budget, usedMinorUnits: usedByParent[categoryID] ?? 0
                    )
                )
            } else {
                total = try BudgetProgress(budget: budget, usedMinorUnits: totalUsed)
            }
        }
        return MonthlyBudgetProgress(
            total: total,
            categories: categories.sorted { $0.usedMinorUnits > $1.usedMinorUnits }
        )
    }

    // MARK: - 私有

    /// 单笔流水对总预算已用额的贡献。只服从预算查询层的 `isExcludedFromBudget`，
    /// 不读取 `isExcludedFromStats`：两个开关在 schema 中是彼此独立的投影口径。
    private func budgetExpenseMinorUnits(of transaction: Transaction) throws -> Int {
        guard let kind = transaction.kind else { return 0 }
        let fee = try budgetBaseMinorUnits(transaction.feeMinorUnits, of: transaction)
        switch kind {
        case .expense:
            return try MoneyArithmetic.add(
                budgetBaseMinorUnits(transaction.amountMinorUnits, of: transaction), fee
            )
        case .income, .transfer:
            return fee
        }
    }

    /// 预算与统计共用“按流水汇率快照折本位币”这一基础换算，但不共用统计排除开关。
    private func budgetBaseMinorUnits(
        _ minorUnits: Int, of transaction: Transaction
    ) throws -> Int {
        try transaction.checkedStatsBaseMinorUnits(minorUnits)
    }

    /// 每个预算维度（categoryID，nil = 总预算）取生效行：当月实体行优先，无则回落模板行。
    private func effectiveBudgets(ledgerID: UUID, year: Int, month: Int) throws -> [Budget] {
        let optYear: Int? = year
        let optMonth: Int? = month
        let rows = try context.fetch(
            FetchDescriptor<Budget>(predicate: #Predicate {
                !$0.isSoftDeleted && $0.ledgerID == ledgerID
                    && ($0.periodYear == nil || ($0.periodYear == optYear && $0.periodMonth == optMonth))
            })
        )
        var effective: [UUID?: Budget] = [:]
        for row in rows {
            if let existing = effective[row.categoryID] {
                let rowIsMonthly = row.periodYear != nil
                let existingIsMonthly = existing.periodYear != nil
                if rowIsMonthly != existingIsMonthly {
                    if rowIsMonthly {
                        effective[row.categoryID] = row // 实体行覆盖模板行
                    }
                } else if row.updatedAt > existing.updatedAt
                            || (row.updatedAt == existing.updatedAt
                                && row.uuid.uuidString < existing.uuid.uuidString) {
                    // 旁路写入造成重复时仍给出稳定结果；正常写路径会拒绝重复维度。
                    effective[row.categoryID] = row
                }
            } else {
                effective[row.categoryID] = row
            }
        }
        return Array(effective.values)
    }
}

enum BudgetProgressError: LocalizedError {
    case invalidMonth

    var errorDescription: String? {
        switch self {
        case .invalidMonth: ZanzanLocalization.string( "无效的预算月份")
        }
    }
}
