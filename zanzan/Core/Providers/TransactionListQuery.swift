import Foundation
import SwiftData

/// 明细列表筛选 + 日/月小计投影（路线图 M1「明细页打磨」逻辑层）。
/// 谓词下推命中复合索引 (isSoftDeleted, ledgerID, occurredAt)；
/// 账户筛选穿关系（收支账户或转账双方），小计口径复用 statsIncome/Expense 派生。
struct TransactionListFilter {
    var ledgerID: UUID
    /// nil = 全部类型
    var kind: TransactionKind? = nil
    /// nil = 全部账户；命中收支账户或转账双方
    var accountUUID: UUID? = nil
    /// nil = 全部标签；多对多关系谓词表达不了，走内存二次收窄（设计文档 §4）
    var tagUUID: UUID? = nil

    /// 谓词下推 + 标签内存筛选的统一取数入口。
    func fetch(in context: ModelContext) throws -> [Transaction] {
        let results = try context.fetch(fetchDescriptor())
        guard let tagUUID else { return results }
        return results.filter { tx in
            tx.tags?.contains { $0.uuid == tagUUID } ?? false
        }
    }

    func fetchDescriptor() -> FetchDescriptor<Transaction> {
        FetchDescriptor<Transaction>(
            predicate: predicate(),
            sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
        )
    }

    /// 按筛选组合展开四个谓词分支——单个大谓词会让 #Predicate 类型检查超时。
    private func predicate() -> Predicate<Transaction> {
        let id: UUID? = ledgerID
        switch (kind?.rawValue, accountUUID) {
        case (nil, nil):
            return #Predicate { !$0.isSoftDeleted && $0.ledgerID == id }
        case let (kindRaw?, nil):
            return #Predicate {
                !$0.isSoftDeleted && $0.ledgerID == id && $0.kindRawValue == kindRaw
            }
        case let (nil, accountID?):
            let optionalAccountID: UUID? = accountID
            return #Predicate {
                !$0.isSoftDeleted && $0.ledgerID == id
                    && ($0.account?.uuid == optionalAccountID || $0.targetAccount?.uuid == optionalAccountID)
            }
        case let (kindRaw?, accountID?):
            let optionalAccountID: UUID? = accountID
            return #Predicate {
                !$0.isSoftDeleted && $0.ledgerID == id && $0.kindRawValue == kindRaw
                    && ($0.account?.uuid == optionalAccountID || $0.targetAccount?.uuid == optionalAccountID)
            }
        }
    }
}

enum TransactionListGrouping {
    struct DayGroup {
        let day: Date
        let incomeTotalMinorUnits: Int
        let expenseTotalMinorUnits: Int
        let items: [Transaction]
    }

    struct MonthGroup {
        let month: Date
        let incomeTotalMinorUnits: Int
        let expenseTotalMinorUnits: Int
        let days: [DayGroup]
    }

    /// 组序月降、日降；isExcludedFromStats 的流水照常在 items，仅不计小计（stats 派生已归零）。
    static func monthGroups(of transactions: [Transaction], calendar: Calendar = .current) -> [MonthGroup] {
        let byMonth = Dictionary(grouping: transactions) {
            calendar.date(from: calendar.dateComponents([.year, .month], from: $0.occurredAt)) ?? $0.occurredAt
        }
        return byMonth
            .sorted { $0.key > $1.key }
            .map { month, monthItems in
                let days = Dictionary(grouping: monthItems) { calendar.startOfDay(for: $0.occurredAt) }
                    .sorted { $0.key > $1.key }
                    .map { day, dayItems in
                        DayGroup(
                            day: day,
                            incomeTotalMinorUnits: dayItems.reduce(0) { $0 + $1.statsIncomeMinorUnits },
                            expenseTotalMinorUnits: dayItems.reduce(0) { $0 + $1.statsExpenseMinorUnits },
                            items: dayItems
                        )
                    }
                return MonthGroup(
                    month: month,
                    incomeTotalMinorUnits: days.reduce(0) { $0 + $1.incomeTotalMinorUnits },
                    expenseTotalMinorUnits: days.reduce(0) { $0 + $1.expenseTotalMinorUnits },
                    days: days
                )
            }
    }
}
