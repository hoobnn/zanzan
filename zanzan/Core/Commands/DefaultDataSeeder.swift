import Foundation
import SwiftData

/// 首启种子（设计文档 §4）：幂等写入默认账本、默认账户、默认两级分类；
/// 完成标记走 StoredMeta dataMigration.* 惯例（13.3 幂等命令迁移同款机制）。
struct DefaultDataSeeder {
    static let completionKey = "dataMigration.defaultSeed"

    let context: ModelContext

    func seedIfNeeded() throws {
        let key = Self.completionKey
        let doneCount = try context.fetchCount(
            FetchDescriptor<StoredMeta>(predicate: #Predicate { $0.key == key })
        )
        guard doneCount == 0 else { return }

        try LedgerCommands(context: context).createLedger(LedgerDraft(name: "日常账本"))

        let cash = StoredAccount(name: "现金", kind: .fund)
        cash.iconKindRawValue = StoredIconDescriptor.Kind.symbol.rawValue
        cash.iconPrimary = "banknote"
        context.insert(cash)

        seedCategories(kind: .expense, tree: Self.expenseTree)
        seedCategories(kind: .income, tree: Self.incomeTree)

        context.insert(StoredMeta(key: key, value: "done"))
        try context.save()
    }

    // MARK: - 种子数据

    private struct SeedCategory {
        let name: String
        let symbol: String
        var children: [(name: String, symbol: String)] = []
    }

    private static let expenseTree: [SeedCategory] = [
        SeedCategory(name: "餐饮", symbol: "fork.knife", children: [
            ("早餐", "sunrise"), ("午餐", "sun.max"), ("晚餐", "moon"), ("饮料零食", "cup.and.saucer"),
        ]),
        SeedCategory(name: "交通", symbol: "car"),
        SeedCategory(name: "购物", symbol: "cart"),
        SeedCategory(name: "居住", symbol: "house"),
        SeedCategory(name: "娱乐", symbol: "gamecontroller"),
        SeedCategory(name: "医疗", symbol: "cross.case"),
        SeedCategory(name: "人情", symbol: "gift"),
        SeedCategory(name: "其他", symbol: "ellipsis.circle"),
    ]

    private static let incomeTree: [SeedCategory] = [
        SeedCategory(name: "工资", symbol: "banknote"),
        SeedCategory(name: "奖金", symbol: "star"),
        SeedCategory(name: "理财收益", symbol: "chart.line.uptrend.xyaxis"),
        SeedCategory(name: "其他收入", symbol: "tray.and.arrow.down"),
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

    private func makeCategory(name: String, symbol: String, kind: TransactionKind, sortOrder: Int) -> StoredCategory {
        let category = StoredCategory(name: name, kind: kind, sortOrder: sortOrder)
        category.iconKindRawValue = StoredIconDescriptor.Kind.symbol.rawValue
        category.iconPrimary = symbol
        category.isBuiltIn = true
        return category
    }
}
