import Foundation
import SwiftData

/// 首启种子（设计文档 §4）：幂等写入默认账本、默认账户、默认两级分类；
/// 完成标记走 AppMeta dataMigration.* 惯例（13.3 幂等命令迁移同款机制）。
struct DefaultDataSeeder {
    static let completionKey = "dataMigration.defaultSeed"
    static let exampleTransactionsCompletionKey = "dataMigration.exampleTransactions.v1"

    let context: ModelContext

    func seedIfNeeded() throws {
        try seedDefaultsIfNeeded()
    }

    private func seedDefaultsIfNeeded() throws {
        let key = Self.completionKey
        let doneCount = try context.fetchCount(
            FetchDescriptor<AppMeta>(predicate: #Predicate { $0.key == key })
        )
        guard doneCount == 0 else { return }

        // 自愈：createLedger 内部 save 与最终标记 save 之间崩溃会留下"只有账本"的半状态，
        // 重放时跳过建账本（否则再建一本且非默认），账户/分类/标记随下方原子 save 补齐
        let ledgerCount = try context.fetchCount(
            FetchDescriptor<Ledger>(predicate: #Predicate { !$0.isSoftDeleted })
        )
        if ledgerCount == 0 {
            try LedgerService(context: context).createLedger(
                LedgerDraft(name: ZanzanLocalization.string("日常账本", language: .simplifiedChinese))
            )
        }

        let cash = Account(
            name: ZanzanLocalization.string("现金", language: .simplifiedChinese),
            kind: .fund
        )
        cash.iconKindRawValue = IconDescriptor.Kind.symbol.rawValue
        cash.iconPrimary = "banknote"
        context.insert(cash)

        seedCategories(kind: .expense, tree: Self.expenseTree)
        seedCategories(kind: .income, tree: Self.incomeTree)

        context.insert(AppMeta(key: key, value: "done"))
        try context.zanzanSave()
    }

    /// 仅供内存 UI 测试补观察数据；生产首启不得写入虚假流水。
    func seedUITestTransactionsIfNeeded() throws {
        let key = Self.exampleTransactionsCompletionKey
        let doneCount = try context.fetchCount(
            FetchDescriptor<AppMeta>(predicate: #Predicate { $0.key == key })
        )
        guard doneCount == 0 else { return }

        let transactionCount = try context.fetchCount(
            FetchDescriptor<Transaction>(predicate: #Predicate { !$0.isSoftDeleted })
        )
        guard transactionCount == 0 else {
            context.insert(AppMeta(key: key, value: "skipped-existing-data"))
            try context.zanzanSave()
            return
        }

        let ledgers = try context.fetch(
            FetchDescriptor<Ledger>(predicate: #Predicate { !$0.isSoftDeleted && !$0.isArchived })
        )
        let accounts = try context.fetch(
            FetchDescriptor<Account>(
                predicate: #Predicate {
                    !$0.isSoftDeleted && !$0.isArchived && $0.isSelectableForRecord
                }
            )
        )
        let categories = try context.fetch(
            FetchDescriptor<Category>(
                predicate: #Predicate { !$0.isSoftDeleted && !$0.isArchived && $0.isBuiltIn }
            )
        )
        guard let ledger = ledgers.first(where: \.isDefault) ?? ledgers.first,
              let account = accounts.first,
              categories.contains(where: { $0.kind == .expense }),
              categories.contains(where: { $0.kind == .income }) else {
            context.insert(AppMeta(key: key, value: "skipped-missing-prerequisites"))
            try context.zanzanSave()
            return
        }

        let now = Date.now
        let calendar = Calendar.current
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let service = TransactionService(context: context)

        func stage(
            kind: TransactionKind,
            amount: String,
            categorySymbol: String,
            note: String,
            hoursAgo: Int
        ) throws {
            guard let category = categories.first(where: {
                $0.kind == kind && $0.iconPrimary == categorySymbol
            }) else { return }
            var draft = TransactionDraft()
            draft.kind = kind
            draft.amountString = amount
            draft.occurredAt = max(
                calendar.date(byAdding: .hour, value: -hoursAgo, to: now) ?? now,
                monthStart
            )
            draft.note = note
            draft.accountUUID = account.uuid
            draft.categoryUUID = category.uuid
            try service.stageTransaction(draft, ledgerID: ledger.uuid)
        }

        try stage(
            kind: .expense,
            amount: "16.80",
            categorySymbol: "sunrise",
            note: "示例 · 早餐面包",
            hoursAgo: 2
        )
        try stage(
            kind: .expense,
            amount: "22.00",
            categorySymbol: "cup.and.saucer",
            note: "示例 · 午后咖啡",
            hoursAgo: 7
        )
        try stage(
            kind: .expense,
            amount: "6.00",
            categorySymbol: "car",
            note: "示例 · 通勤地铁",
            hoursAgo: 25
        )
        try stage(
            kind: .expense,
            amount: "186.35",
            categorySymbol: "cart",
            note: "示例 · 周末采购",
            hoursAgo: 49
        )
        try stage(
            kind: .expense,
            amount: "58.00",
            categorySymbol: "gamecontroller",
            note: "示例 · 电影票",
            hoursAgo: 73
        )
        try stage(
            kind: .income,
            amount: "8800.00",
            categorySymbol: "banknote",
            note: "示例 · 工资到账",
            hoursAgo: 97
        )

        context.insert(AppMeta(key: key, value: "done"))
        try context.zanzanSave()
    }

    /// 种子树里某内置子分类的默认父类图标（「恢复默认分类」重挂父指针用）。
    /// 图标是稳定标识，不受应用语言或用户改名影响。
    static func defaultParentSymbol(forChildSymbol symbol: String, kind: TransactionKind?) -> String? {
        guard let kind else { return nil }
        let tree = kind == .expense ? expenseTree : incomeTree
        return tree.first { $0.children.contains { $0.symbol == symbol } }?.symbol
    }

    // MARK: - 种子数据

    private struct SeedCategory {
        let name: String
        let symbol: String
        var children: [(name: String, symbol: String)] = []
    }

    private static let expenseTree: [SeedCategory] = [
        SeedCategory(name: ZanzanLocalization.string("餐饮", language: .simplifiedChinese), symbol: "fork.knife", children: [
            (ZanzanLocalization.string("早餐", language: .simplifiedChinese), "sunrise"),
            (ZanzanLocalization.string("午餐", language: .simplifiedChinese), "sun.max"),
            (ZanzanLocalization.string("晚餐", language: .simplifiedChinese), "moon"),
            (ZanzanLocalization.string("饮料零食", language: .simplifiedChinese), "cup.and.saucer"),
        ]),
        SeedCategory(name: ZanzanLocalization.string("交通", language: .simplifiedChinese), symbol: "car"),
        SeedCategory(name: ZanzanLocalization.string("购物", language: .simplifiedChinese), symbol: "cart"),
        SeedCategory(name: ZanzanLocalization.string("居住", language: .simplifiedChinese), symbol: "house"),
        SeedCategory(name: ZanzanLocalization.string("娱乐", language: .simplifiedChinese), symbol: "gamecontroller"),
        SeedCategory(name: ZanzanLocalization.string("医疗", language: .simplifiedChinese), symbol: "cross.case"),
        SeedCategory(name: ZanzanLocalization.string("人情", language: .simplifiedChinese), symbol: "gift"),
        SeedCategory(name: ZanzanLocalization.string("其他", language: .simplifiedChinese), symbol: "ellipsis.circle"),
    ]

    private static let incomeTree: [SeedCategory] = [
        SeedCategory(name: ZanzanLocalization.string("工资", language: .simplifiedChinese), symbol: "banknote"),
        SeedCategory(name: ZanzanLocalization.string("奖金", language: .simplifiedChinese), symbol: "star"),
        SeedCategory(name: ZanzanLocalization.string("理财收益", language: .simplifiedChinese), symbol: "chart.line.uptrend.xyaxis"),
        SeedCategory(name: ZanzanLocalization.string("其他收入", language: .simplifiedChinese), symbol: "tray.and.arrow.down"),
    ]

    private func seedCategories(kind: TransactionKind, tree: [SeedCategory]) {
        for (index, seed) in tree.enumerated() {
            let parent = makeCategory(name: seed.name, symbol: seed.symbol, kind: kind, sortOrder: index)
            context.insert(parent)
            for (childIndex, child) in seed.children.enumerated() {
                let category = makeCategory(name: child.name, symbol: child.symbol, kind: kind, sortOrder: childIndex)
                category.parentID = parent.uuid
                context.insert(category)
            }
        }
    }

    private func makeCategory(name: String, symbol: String, kind: TransactionKind, sortOrder: Int) -> Category {
        let category = Category(name: name, kind: kind, sortOrder: sortOrder)
        category.iconKindRawValue = IconDescriptor.Kind.symbol.rawValue
        category.iconPrimary = symbol
        category.isBuiltIn = true
        return category
    }
}
