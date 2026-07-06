import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct InstallmentSchemaTests {
    @Test func 分期计划往返与状态默认值() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let plan = StoredInstallmentPlan(
            name: "iPhone 24 期",
            kind: .purchase,
            accountID: UUID(),
            ledgerID: UUID(),
            principalMinorUnits: 999_900,
            totalPeriods: 24,
            amortizationKind: .flatFee,
            firstDueAt: .now
        )
        context.insert(plan)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<StoredInstallmentPlan>()).first)
        #expect(fetched.kind == .purchase)
        #expect(fetched.amortizationKind == .flatFee)
        #expect(fetched.status == .active)
        #expect(fetched.annualRateBps == nil) // 固定手续费类分期无年利率
        #expect(fetched.closedAt == nil)
        #expect(!fetched.isAutoSettle)
        #expect(fetched.totalPeriods == 24)
    }

    @Test func 期数行往返与回填字段() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let planID = UUID()
        let period = StoredInstallmentPeriod(
            planID: planID,
            periodIndex: 1,
            dueAt: .now,
            principalMinorUnits: 41_663,
            interestMinorUnits: 2_500
        )
        context.insert(period)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<StoredInstallmentPeriod>()).first)
        #expect(fetched.planID == planID)
        #expect(fetched.periodIndex == 1)
        #expect(fetched.status == .pending)
        #expect(fetched.settledAt == nil)
        #expect(fetched.settledTransactionID == nil)
    }

    @Test func 按计划与期序谓词查询() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let planID = UUID()
        for index in 1...3 {
            context.insert(StoredInstallmentPeriod(
                planID: planID, periodIndex: index, dueAt: .now,
                principalMinorUnits: 100, interestMinorUnits: 0
            ))
        }
        context.insert(StoredInstallmentPeriod(
            planID: UUID(), periodIndex: 1, dueAt: .now,
            principalMinorUnits: 100, interestMinorUnits: 0
        ))
        try context.save()

        let descriptor = FetchDescriptor<StoredInstallmentPeriod>(
            predicate: #Predicate { $0.planID == planID },
            sortBy: [SortDescriptor(\.periodIndex)]
        )
        let fetched = try context.fetch(descriptor)
        #expect(fetched.count == 3)
        #expect(fetched.map(\.periodIndex) == [1, 2, 3])
    }
}
