import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct DefaultDataSeederTests {
    @Test func 首启写入默认账本账户与两级分类() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        try DefaultDataSeeder(context: context).seedIfNeeded()

        let ledgers = try context.fetch(FetchDescriptor<Ledger>())
        #expect(ledgers.count == 1)
        #expect(ledgers.first?.isDefault == true)

        let accounts = try context.fetch(FetchDescriptor<Account>())
        #expect(accounts.count == 1)
        #expect(accounts.first?.kind == .fund)

        let categories = try context.fetch(FetchDescriptor<Category>())
        let allBuiltIn = categories.allSatisfy(\.isBuiltIn)
        let allGlobal = categories.allSatisfy { $0.ledgerID == nil }
        #expect(allBuiltIn)
        #expect(allGlobal) // 全局分类
        let expenseRoots = categories.filter { $0.kind == .expense && $0.parentID == nil }
        let incomeRoots = categories.filter { $0.kind == .income && $0.parentID == nil }
        #expect(expenseRoots.count == 8)
        #expect(incomeRoots.count == 4)
        // 两级树：餐饮下有子类且 parentID 正确
        let diningName = ZanzanLocalization.string("餐饮", language: .simplifiedChinese)
        let dining = try #require(expenseRoots.first { $0.name == diningName })
        let children = categories.filter { $0.parentID == dining.uuid }
        #expect(children.count == 4)

        #expect(try context.fetchCount(FetchDescriptor<Transaction>()) == 0)
    }

    @Test func 半状态重放自愈不重复建账本() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        // 模拟"createLedger 已 save、完成标记未落"的崩溃现场
        let ledgerName = ZanzanLocalization.string("日常账本", language: .simplifiedChinese)
        try LedgerService(context: context).createLedger(LedgerDraft(name: ledgerName))

        try DefaultDataSeeder(context: context).seedIfNeeded()

        let ledgers = try context.fetch(FetchDescriptor<Ledger>())
        #expect(ledgers.count == 1) // 不再建第二本
        #expect(ledgers.first?.isDefault == true)
        // 账户/分类/标记随重放补齐
        #expect(try context.fetchCount(FetchDescriptor<Account>()) == 1)
        #expect(try context.fetch(FetchDescriptor<Category>()).contains { $0.isBuiltIn })
        let key = DefaultDataSeeder.completionKey
        let metas = try context.fetch(FetchDescriptor<AppMeta>(predicate: #Predicate { $0.key == key }))
        #expect(metas.count == 1)
        // 再跑一次仍幂等
        try DefaultDataSeeder(context: context).seedIfNeeded()
        #expect(try context.fetchCount(FetchDescriptor<Ledger>()) == 1)
    }

    @Test func 幂等重跑不产生重复() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let seeder = DefaultDataSeeder(context: context)
        try seeder.seedIfNeeded()
        let firstCount = try context.fetch(FetchDescriptor<Category>()).count
        try seeder.seedIfNeeded()
        let secondCount = try context.fetch(FetchDescriptor<Category>()).count
        let ledgerCount = try context.fetch(FetchDescriptor<Ledger>()).count
        let transactionCount = try context.fetchCount(FetchDescriptor<Transaction>())
        #expect(secondCount == firstCount)
        #expect(ledgerCount == 1)
        #expect(transactionCount == 0)
        let key = DefaultDataSeeder.completionKey
        let metas = try context.fetch(FetchDescriptor<AppMeta>(predicate: #Predicate { $0.key == key }))
        #expect(metas.count == 1)
    }

    @Test func UI测试可显式写入幂等示例数据() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let seeder = DefaultDataSeeder(context: context)
        try seeder.seedIfNeeded()

        try seeder.seedUITestTransactionsIfNeeded()
        try seeder.seedUITestTransactionsIfNeeded()

        let transactions = try context.fetch(FetchDescriptor<Transaction>())
        #expect(transactions.count == 6)
        #expect(transactions.contains { $0.note == "示例 · 工资到账" })
        let ledger = try #require(try context.fetch(FetchDescriptor<Ledger>()).first)
        #expect(transactions.allSatisfy { $0.ledgerID == ledger.uuid })
    }

    @Test func UI测试数据不会混入已有流水() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let ledger = try LedgerService(context: context).createLedger(LedgerDraft(name: "已有账本"))
        let account = Account(name: "已有账户", kind: .fund)
        let category = Category(name: "已有分类", kind: .expense, sortOrder: 0)
        context.insert(account)
        context.insert(category)
        try context.zanzanSave()

        var draft = TransactionDraft()
        draft.amountString = "1.00"
        draft.accountUUID = account.uuid
        draft.categoryUUID = category.uuid
        try TransactionService(context: context).recordTransaction(draft, ledgerID: ledger.uuid)

        try DefaultDataSeeder(context: context).seedUITestTransactionsIfNeeded()

        let transactions = try context.fetch(FetchDescriptor<Transaction>())
        #expect(transactions.count == 1)
        #expect(transactions.first?.note.isEmpty == true)
        let key = DefaultDataSeeder.exampleTransactionsCompletionKey
        let metas = try context.fetch(FetchDescriptor<AppMeta>(predicate: #Predicate { $0.key == key }))
        #expect(metas.first?.value == "skipped-existing-data")
    }
}
