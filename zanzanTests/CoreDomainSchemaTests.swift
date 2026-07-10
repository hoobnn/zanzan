import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct CoreDomainSchemaTests {
    @Test func 流水关联行往返() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let originalID = UUID()
        let settlementID = UUID()
        let link = TransactionLink(
            originalTransactionID: originalID,
            settlementTransactionID: settlementID,
            kind: .reimbursement,
            amountMinorUnits: 60000
        )
        context.insert(link)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<TransactionLink>()).first)
        #expect(fetched.originalTransactionID == originalID)
        #expect(fetched.settlementTransactionID == settlementID)
        #expect(fetched.kind == .reimbursement)
        #expect(fetched.amountMinorUnits == 60000)
    }

    @Test func 预算模板行与按月实体行语义() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let ledgerID = UUID()
        let template = Budget(ledgerID: ledgerID, amountMinorUnits: 300_000)
        let monthly = Budget(ledgerID: ledgerID, amountMinorUnits: 500_000)
        monthly.periodYear = 2026
        monthly.periodMonth = 7
        context.insert(template)
        context.insert(monthly)
        try context.save()

        let all = try context.fetch(FetchDescriptor<Budget>())
        #expect(all.count == 2)
        let fetchedTemplate = try #require(all.first { $0.periodYear == nil })
        #expect(fetchedTemplate.periodMonth == nil) // 与 periodYear 同空同有
        #expect(fetchedTemplate.categoryID == nil)  // nil = 总预算
        #expect(fetchedTemplate.ledgerID == ledgerID)
    }

    @Test func 授信池往返() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let pool = CreditPool(name: "招商银行", totalLimitMinorUnits: 10_000_000)
        context.insert(pool)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<CreditPool>()).first)
        #expect(fetched.name == "招商银行")
        #expect(fetched.totalLimitMinorUnits == 10_000_000)
        #expect(fetched.currencyCode == "CNY")
        #expect(fetched.note.isEmpty)
    }
}
