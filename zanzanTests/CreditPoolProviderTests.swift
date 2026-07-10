import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct CreditPoolProviderTests {
    private func makeMemberCard(context: ModelContext, pool: CreditPool, name: String) -> Account {
        let card = Account(name: name, kind: .credit)
        card.creditPoolID = pool.uuid
        context.insert(card)
        return card
    }

    private func addExpense(context: ModelContext, account: Account, amount: Int) {
        let tx = Transaction(kind: .expense, amountMinorUnits: amount, occurredAt: .now, ledgerID: UUID())
        tx.account = account
        context.insert(tx)
    }

    @Test func 池已用等于成员欠款之和() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let pool = CreditPool(name: "招商银行", totalLimitMinorUnits: 100_000)
        context.insert(pool)
        let cardA = makeMemberCard(context: context, pool: pool, name: "卡A")
        let cardB = makeMemberCard(context: context, pool: pool, name: "卡B")
        addExpense(context: context, account: cardA, amount: 30_000)
        addExpense(context: context, account: cardB, amount: 20_000)
        try context.save()

        let overview = try CreditPoolProvider(context: context).overview(poolUUID: pool.uuid)
        #expect(overview.totalLimitMinorUnits == 100_000)
        #expect(overview.usedMinorUnits == 50_000)
        #expect(overview.availableMinorUnits == 50_000)
    }

    @Test func 溢缴款不释放池额度() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let pool = CreditPool(name: "招商银行", totalLimitMinorUnits: 100_000)
        context.insert(pool)
        let owing = makeMemberCard(context: context, pool: pool, name: "欠款卡")
        addExpense(context: context, account: owing, amount: 30_000)
        // 溢缴卡派生余额为正（期初 5000 无支出），按欠款 0 计，不冲抵他卡占用
        let overpaid = makeMemberCard(context: context, pool: pool, name: "溢缴卡")
        overpaid.initialBalanceMinorUnits = 5_000
        try context.save()

        let overview = try CreditPoolProvider(context: context).overview(poolUUID: pool.uuid)
        #expect(overview.usedMinorUnits == 30_000)
        #expect(overview.availableMinorUnits == 70_000)
    }

    @Test func 池已用超总额度_可用额度下限为零() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let pool = CreditPool(name: "招商银行", totalLimitMinorUnits: 10_000)
        context.insert(pool)
        let card = makeMemberCard(context: context, pool: pool, name: "卡A")
        addExpense(context: context, account: card, amount: 15_000)
        try context.save()

        let overview = try CreditPoolProvider(context: context).overview(poolUUID: pool.uuid)
        #expect(overview.usedMinorUnits == 15_000)
        #expect(overview.availableMinorUnits == 0)
    }

    @Test func 软删成员卡不计入池已用() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let pool = CreditPool(name: "招商银行", totalLimitMinorUnits: 100_000)
        context.insert(pool)
        let active = makeMemberCard(context: context, pool: pool, name: "在用卡")
        addExpense(context: context, account: active, amount: 10_000)
        let deleted = makeMemberCard(context: context, pool: pool, name: "已删卡")
        deleted.isSoftDeleted = true
        addExpense(context: context, account: deleted, amount: 99_999)
        try context.save()

        let overview = try CreditPoolProvider(context: context).overview(poolUUID: pool.uuid)
        #expect(overview.usedMinorUnits == 10_000)
    }

    @Test func 查询软删池抛错() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let pool = CreditPool(name: "招商银行", totalLimitMinorUnits: 100_000)
        pool.isSoftDeleted = true
        context.insert(pool)
        try context.save()

        #expect(throws: CreditPoolProviderError.self) {
            try CreditPoolProvider(context: context).overview(poolUUID: pool.uuid)
        }
    }
}
