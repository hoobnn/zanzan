import Foundation
import SwiftData

/// 首启种子（设计文档 §4）：幂等写入默认账本、默认账户、默认两级分类；
/// 完成标记走 AppMeta dataMigration.* 惯例（13.3 幂等命令迁移同款机制）。
struct DefaultDataSeeder {
    static let completionKey = "dataMigration.defaultSeed"

    let context: ModelContext

    func seedIfNeeded() throws {
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
            try LedgerService(context: context).createLedger(LedgerDraft(name: String(localized: "日常账本")))
        }

        let cash = Account(name: String(localized: "现金"), kind: .fund)
        cash.iconKindRawValue = IconDescriptor.Kind.symbol.rawValue
        cash.iconPrimary = "banknote"
        context.insert(cash)

        seedCategories(kind: .expense, tree: Self.expenseTree)
        seedCategories(kind: .income, tree: Self.incomeTree)

        context.insert(AppMeta(key: key, value: "done"))
        try context.save()
    }

    /// 种子树里某内置子分类的默认父类名（「恢复默认分类」重挂父指针用）；
    /// 非种子子分类名（含用户已改名）返回 nil。
    static func defaultParentName(forChildNamed name: String, kind: TransactionKind?) -> String? {
        guard let kind else { return nil }
        let tree = kind == .expense ? expenseTree : incomeTree
        return tree.first { $0.children.contains { $0.name == name } }?.name
    }

    // MARK: - 种子数据

    private struct SeedCategory {
        let name: String
        let symbol: String
        var children: [(name: String, symbol: String)] = []
    }

    private static let expenseTree: [SeedCategory] = [
        SeedCategory(name: String(localized: "餐饮"), symbol: "fork.knife", children: [
            (String(localized: "早餐"), "sunrise"), (String(localized: "午餐"), "sun.max"), (String(localized: "晚餐"), "moon"), (String(localized: "饮料零食"), "cup.and.saucer"),
        ]),
        SeedCategory(name: String(localized: "交通"), symbol: "car"),
        SeedCategory(name: String(localized: "购物"), symbol: "cart"),
        SeedCategory(name: String(localized: "居住"), symbol: "house"),
        SeedCategory(name: String(localized: "娱乐"), symbol: "gamecontroller"),
        SeedCategory(name: String(localized: "医疗"), symbol: "cross.case"),
        SeedCategory(name: String(localized: "人情"), symbol: "gift"),
        SeedCategory(name: String(localized: "其他"), symbol: "ellipsis.circle"),
    ]

    private static let incomeTree: [SeedCategory] = [
        SeedCategory(name: String(localized: "工资"), symbol: "banknote"),
        SeedCategory(name: String(localized: "奖金"), symbol: "star"),
        SeedCategory(name: String(localized: "理财收益"), symbol: "chart.line.uptrend.xyaxis"),
        SeedCategory(name: String(localized: "其他收入"), symbol: "tray.and.arrow.down"),
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
