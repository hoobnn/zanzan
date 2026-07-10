import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct TransactionClusterSchemaTests {
    @Test func 支出流水与账户分类标签关系往返() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let ledger = Ledger(name: "日常")
        let account = Account(name: "招行储蓄卡", kind: .fund)
        let category = Category(name: "餐饮", kind: .expense, sortOrder: 0)
        let tag = Tag(name: "出差")
        context.insert(ledger)
        context.insert(account)
        context.insert(category)
        context.insert(tag)

        let txn = Transaction(
            kind: .expense, amountMinorUnits: 2500,
            occurredAt: .now, ledgerID: ledger.uuid
        )
        txn.account = account
        txn.category = category
        txn.tags = [tag]
        context.insert(txn)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<Transaction>()).first)
        #expect(fetched.kind == .expense)
        #expect(fetched.account?.name == "招行储蓄卡")
        #expect(fetched.category?.name == "餐饮")
        #expect(fetched.tags?.count == 1)
        #expect(fetched.currencyCode == "CNY")
        #expect(fetched.sourceKind == .manual)
        #expect(fetched.attachmentFileNames.isEmpty)

        // 显式 inverse：反向可达
        #expect(account.transactions?.count == 1)
        #expect(category.transactions?.count == 1)
        #expect(tag.transactions?.count == 1)
    }

    @Test func 转账流水双账户与到账金额往返() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let source = Account(name: "招行卡", kind: .fund)
        let target = Account(name: "美元账户", kind: .fund)
        context.insert(source)
        context.insert(target)

        let txn = Transaction(
            kind: .transfer, amountMinorUnits: 72000,
            occurredAt: .now, ledgerID: UUID()
        )
        txn.account = source
        txn.targetAccount = target
        txn.targetAmountMinorUnits = 10000
        txn.fxRateToBase = Decimal(string: "7.2")
        context.insert(txn)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<Transaction>()).first)
        #expect(fetched.targetAccount?.name == "美元账户")
        #expect(fetched.targetAmountMinorUnits == 10000)
        #expect(fetched.fxRateToBase == Decimal(string: "7.2"))
        #expect(target.incomingTransfers?.count == 1)
        #expect(target.transactions?.isEmpty != false)
    }

    @Test func 语义类枚举未知值解析为nil且原串保留() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let txn = Transaction(
            kind: .expense, amountMinorUnits: 100,
            occurredAt: .now, ledgerID: UUID()
        )
        txn.kindRawValue = "cryptoStaking" // 未来版本写入的未知值
        context.insert(txn)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<Transaction>()).first)
        #expect(fetched.kind == nil)
        #expect(fetched.kindRawValue == "cryptoStaking")
        #expect(fetched.reimbursementStatus == nil) // 空串 = 非报销
        #expect(fetched.settlementKind == nil)      // 空串 = 非到账单
    }

    @Test func 账户信用字段与开关默认值() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let card = Account(name: "招行信用卡", kind: .credit)
        card.creditLimitMinorUnits = 5_000_000
        card.statementDay = 5
        card.paymentDueDay = 23
        context.insert(card)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<Account>()).first)
        #expect(fetched.kind == .credit)
        #expect(fetched.creditLimitMinorUnits == 5_000_000)
        #expect(fetched.creditPoolID == nil)
        #expect(fetched.isIncludedInNetWorth)
        #expect(fetched.isSelectableForRecord)
        #expect(!fetched.isArchived)
        #expect(fetched.initialBalanceMinorUnits == 0)
    }

    @Test func 分类两级树与归属字段往返() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let parent = Category(name: "餐饮", kind: .expense, sortOrder: 0)
        let child = Category(name: "早餐", kind: .expense, sortOrder: 0)
        child.parentID = parent.uuid
        context.insert(parent)
        context.insert(child)
        try context.save()

        let all = try context.fetch(FetchDescriptor<Category>())
        let fetchedChild = try #require(all.first { $0.name == "早餐" })
        #expect(fetchedChild.parentID == parent.uuid)
        #expect(fetchedChild.ledgerID == nil) // nil = 全局分类
        #expect(!fetchedChild.isBuiltIn)
    }
}
