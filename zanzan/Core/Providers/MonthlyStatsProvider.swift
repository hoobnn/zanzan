import Foundation
import SwiftData

/// 月度统计只读投影（设计文档 5.3 rollup 口径 / 5.4 统计口径）。
/// 谓词收窄到账本 × 月窗口后一次取回，内存做分类 rollup（关系穿越谓词表达不了）。
struct MonthlyStats {
    struct ChildStat {
        let category: Category
        let amountMinorUnits: Int
    }

    struct CategoryStat {
        /// 一级分类；「父类直挂」与「子类汇总」并列展示（设计文档 5.3）
        let category: Category
        let directMinorUnits: Int
        let children: [ChildStat]
        var totalMinorUnits: Int { directMinorUnits + children.reduce(0) { $0 + $1.amountMinorUnits } }
    }

    /// 各金额均为本位币分（口径①：外币按流水自身汇率快照折算）
    let incomeTotalMinorUnits: Int
    /// 含 fee（fee 恒为流出计入支出统计）
    let expenseTotalMinorUnits: Int
    /// 「利息手续费」合计（裁决 11：fee 无分类归属，由投影器单列口径）
    let feeTotalMinorUnits: Int
    let expenseRanking: [CategoryStat]
    let incomeRanking: [CategoryStat]
}

/// 退款冲减明细（月度统计与预算进度共享，5.4 统计口径）：
/// 经 TransactionLink 反查原单；分摊额以原单币种计（5.5），按**原单**自身汇率快照折本位币（口径①）。
/// 冲减额恒为负值，记入到账单所在月（与 statsExpenseMinorUnits 的总额口径同月生效）。
struct RefundAdjustment {
    /// 原单分类；nil 表示原单无分类（只冲总额，不进分类排行/分类预算）
    let category: Category?
    /// 原单不计预算：预算侧总额与分类均不得冲减（对称性，见 BudgetProgressProvider）
    let isOriginalExcludedFromBudget: Bool
    /// 冲减额（负值，本位币分）
    let amountMinorUnits: Int
}

enum RefundAdjustmentResolver {
    /// 从一批流水中挑出退款到账单并解析冲减明细。
    /// 原单已删/查不到的 link 跳过：月度统计总额仍经到账单自身 statsExpense 冲减，
    /// 预算侧视为不可判定不冲减（缺原单无法读 isExcludedFromBudget，宁可不低估已用）。
    static func adjustments(in transactions: [Transaction], context: ModelContext) throws -> [RefundAdjustment] {
        var adjustments: [RefundAdjustment] = []
        for tx in transactions where tx.kind == .income && tx.settlementKind == .refund {
            let settlementID = tx.uuid
            let links = try context.fetch(FetchDescriptor<TransactionLink>(
                predicate: #Predicate { !$0.isSoftDeleted && $0.settlementTransactionID == settlementID }
            ))
            for link in links {
                let originalID = link.originalTransactionID
                let original = try context.fetch(FetchDescriptor<Transaction>(
                    predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == originalID }
                )).first
                guard let original else { continue }
                adjustments.append(RefundAdjustment(
                    category: original.category,
                    isOriginalExcludedFromBudget: original.isExcludedFromBudget,
                    amountMinorUnits: -original.statsBaseMinorUnits(link.amountMinorUnits)
                ))
            }
        }
        return adjustments
    }
}

struct MonthlyStatsProvider {
    let context: ModelContext

    func stats(ledgerID: UUID, year: Int, month: Int, calendar: Calendar = .current) throws -> MonthlyStats {
        guard
            let monthStart = calendar.date(from: DateComponents(year: year, month: month)),
            let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: monthStart)
        else { throw MonthlyStatsError.invalidMonth }

        let id: UUID? = ledgerID
        let transactions = try context.fetch(
            FetchDescriptor<Transaction>(predicate: #Predicate {
                !$0.isSoftDeleted && $0.ledgerID == id
                    && $0.occurredAt >= monthStart && $0.occurredAt < nextMonthStart
                    && !$0.isExcludedFromStats
            })
        )

        return MonthlyStats(
            incomeTotalMinorUnits: transactions.reduce(0) { $0 + $1.statsIncomeMinorUnits },
            expenseTotalMinorUnits: transactions.reduce(0) { $0 + $1.statsExpenseMinorUnits },
            feeTotalMinorUnits: transactions.reduce(0) { $0 + $1.statsFeeMinorUnits },
            expenseRanking: ranking(
                of: transactions, kind: .expense,
                // 原单无分类的冲减只进总额不进排行（compactMap 剔除）
                adjustments: try RefundAdjustmentResolver.adjustments(in: transactions, context: context)
                    .compactMap { adj in adj.category.map { ($0, adj.amountMinorUnits) } }
            ) { $0.statsBaseMinorUnits($0.amountMinorUnits) }, // 折算后 amount（fee 无分类不进排行）
            incomeRanking: ranking(of: transactions, kind: .income) { $0.statsIncomeMinorUnits }
        )
    }

    // MARK: - 私有

    /// 分类 rollup：二级金额汇入父类。amount 闭包区分口径——
    /// 支出排行计 amount（fee 无分类不进排行），收入排行计报销剔除后口径；
    /// adjustments 为退款冲减项（负值），随同分类汇总。
    private func ranking(
        of transactions: [Transaction],
        kind: TransactionKind,
        adjustments: [(category: Category, amountMinorUnits: Int)] = [],
        amount: (Transaction) -> Int
    ) -> [MonthlyStats.CategoryStat] {
        var directByParent: [UUID: Int] = [:]
        var childAmounts: [UUID: Int] = [:]
        var categoriesByUUID: [UUID: Category] = [:]
        var parentUUIDOfChild: [UUID: UUID] = [:]

        func accumulate(_ category: Category, _ value: Int) {
            categoriesByUUID[category.uuid] = category
            if let parentID = category.parentID,
               let parent = categoriesByUUID[parentID] ?? fetchCategory(parentID) {
                childAmounts[category.uuid, default: 0] += value
                parentUUIDOfChild[category.uuid] = parent.uuid
                categoriesByUUID[parent.uuid] = parent
            } else {
                directByParent[category.uuid, default: 0] += value
            }
        }

        for tx in transactions where tx.kind == kind {
            guard let category = tx.category else { continue } // 脏数据防御：计 total 不进排行
            let value = amount(tx)
            guard value > 0 else { continue }
            accumulate(category, value)
        }
        for adjustment in adjustments {
            accumulate(adjustment.category, adjustment.amountMinorUnits)
        }

        var childrenByParent: [UUID: [MonthlyStats.ChildStat]] = [:]
        for (childUUID, value) in childAmounts {
            guard
                let parentUUID = parentUUIDOfChild[childUUID],
                let child = categoriesByUUID[childUUID]
            else { continue }
            childrenByParent[parentUUID, default: []]
                .append(MonthlyStats.ChildStat(category: child, amountMinorUnits: value))
        }

        let parentUUIDs = Set(directByParent.keys).union(childrenByParent.keys)
        return parentUUIDs
            .compactMap { uuid -> MonthlyStats.CategoryStat? in
                guard let category = categoriesByUUID[uuid] else { return nil }
                let children = (childrenByParent[uuid] ?? []).sorted { $0.amountMinorUnits > $1.amountMinorUnits }
                return MonthlyStats.CategoryStat(
                    category: category,
                    directMinorUnits: directByParent[uuid] ?? 0,
                    children: children
                )
            }
            .sorted { $0.totalMinorUnits > $1.totalMinorUnits }
    }

    private func fetchCategory(_ uuid: UUID) -> Category? {
        try? context.fetch(
            FetchDescriptor<Category>(predicate: #Predicate { $0.uuid == uuid })
        ).first
    }
}

enum MonthlyStatsError: LocalizedError {
    case invalidMonth

    var errorDescription: String? {
        switch self {
        case .invalidMonth: String(localized: "无效的统计月份")
        }
    }
}
