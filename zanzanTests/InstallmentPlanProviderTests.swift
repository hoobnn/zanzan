import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct InstallmentPlanProviderTests {
    private struct Fixture {
        let context: ModelContext
        let ledger: Ledger
        let cash: Account
        let card: Account
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func makeFixture() throws -> Fixture {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let ledger = try LedgerService(context: context).createLedger(LedgerDraft(name: "日常"))
        let cash = Account(name: "现金", kind: .fund)
        let card = Account(name: "信用卡", kind: .credit)
        context.insert(cash)
        context.insert(card)
        try context.save()
        return Fixture(context: context, ledger: ledger, cash: cash, card: card)
    }

    /// 10000 分 / 3 期（3333 / 3333 / 3334，含尾差）/ 每期手续费 100 分
    private func makePlan(_ f: Fixture) throws -> InstallmentPlan {
        var draft = InstallmentPlanDraft(firstDueAt: date(2026, 8, 10))
        draft.name = "iPhone 分期"
        draft.kind = .purchase
        draft.accountID = f.card.uuid
        draft.ledgerID = f.ledger.uuid
        draft.principalMinorUnits = 10_000
        draft.totalPeriods = 3
        draft.amortizationKind = .flatFee
        draft.flatFeePerPeriodMinorUnits = 100
        return try InstallmentService(context: f.context).createPlan(draft, calendar: calendar)
    }

    @Test func 新建计划的初始进度() throws {
        let f = try makeFixture()
        let plan = try makePlan(f)
        let progress = try InstallmentPlanProvider(context: f.context).progress(planUUID: plan.uuid)

        #expect(progress.totalPeriods == 3)
        #expect(progress.settledPeriodCount == 0)
        #expect(progress.paidPrincipalMinorUnits == 0)
        #expect(progress.remainingPrincipalMinorUnits == 10_000)
        #expect(progress.settledInterestMinorUnits == 0)
        #expect(progress.remainingInterestMinorUnits == 300)
        #expect(progress.nextDuePeriod?.periodIndex == 1)
        #expect(progress.nextDuePeriod?.dueAt == date(2026, 8, 10))
    }

    @Test func 记两期后的进度_含尾差仍闭环() throws {
        let f = try makeFixture()
        let plan = try makePlan(f)
        let service = InstallmentService(context: f.context)
        for index in 1...2 {
            _ = try service.settlePeriod(
                planUUID: plan.uuid, periodIndex: index, fromAccountID: f.cash.uuid, at: date(2026, 8, 10 + index)
            )
        }
        let progress = try InstallmentPlanProvider(context: f.context).progress(planUUID: plan.uuid)

        #expect(progress.settledPeriodCount == 2)
        #expect(progress.paidPrincipalMinorUnits == 6_666)      // 3333 + 3333
        #expect(progress.remainingPrincipalMinorUnits == 3_334) // 尾差在末期
        // 进度闭环：已还本金 + 剩余本金 == 总本金
        #expect(progress.paidPrincipalMinorUnits + progress.remainingPrincipalMinorUnits == 10_000)
        #expect(progress.settledInterestMinorUnits == 200)
        #expect(progress.remainingInterestMinorUnits == 100)
        #expect(progress.nextDuePeriod?.periodIndex == 3)
    }

    @Test func 撤销一期后进度回退且闭环仍成立() throws {
        let f = try makeFixture()
        let plan = try makePlan(f)
        let service = InstallmentService(context: f.context)
        for index in 1...2 {
            _ = try service.settlePeriod(
                planUUID: plan.uuid, periodIndex: index, fromAccountID: f.cash.uuid, at: date(2026, 8, 10 + index)
            )
        }
        try service.undoSettlePeriod(planUUID: plan.uuid, periodIndex: 2, at: date(2026, 8, 13))
        let progress = try InstallmentPlanProvider(context: f.context).progress(planUUID: plan.uuid)

        #expect(progress.settledPeriodCount == 1)
        #expect(progress.paidPrincipalMinorUnits == 3_333)      // 仅第 1 期
        #expect(progress.remainingPrincipalMinorUnits == 6_667) // 第 2 期回到待还
        #expect(progress.paidPrincipalMinorUnits + progress.remainingPrincipalMinorUnits == 10_000)
        #expect(progress.nextDuePeriod?.periodIndex == 2) // 回退后最早待还期
    }

    @Test func 提前结清后剩余归零且闭环仍成立() throws {
        let f = try makeFixture()
        let plan = try makePlan(f)
        let service = InstallmentService(context: f.context)
        _ = try service.settlePeriod(
            planUUID: plan.uuid, periodIndex: 1, fromAccountID: f.cash.uuid, at: date(2026, 8, 10)
        )
        _ = try service.settleEarly(
            planUUID: plan.uuid, fromAccountID: f.cash.uuid, penaltyMinorUnits: 500, at: date(2026, 8, 20)
        )
        let progress = try InstallmentPlanProvider(context: f.context).progress(planUUID: plan.uuid)

        #expect(progress.settledPeriodCount == 1)
        #expect(progress.settledPrincipalMinorUnits == 3_333)
        #expect(progress.earlySettledPrincipalMinorUnits == 6_667) // 结清转账覆盖的取消期本金
        #expect(progress.paidPrincipalMinorUnits == 10_000)
        #expect(progress.remainingPrincipalMinorUnits == 0)
        #expect(progress.paidPrincipalMinorUnits + progress.remainingPrincipalMinorUnits == 10_000)
        #expect(progress.remainingInterestMinorUnits == 0) // 取消期利息不再应付
        #expect(progress.nextDuePeriod == nil)
    }

    @Test func 全部记完的进度() throws {
        let f = try makeFixture()
        let plan = try makePlan(f)
        let service = InstallmentService(context: f.context)
        for index in 1...3 {
            _ = try service.settlePeriod(
                planUUID: plan.uuid, periodIndex: index, fromAccountID: f.cash.uuid, at: date(2026, 8, 10 + index)
            )
        }
        let progress = try InstallmentPlanProvider(context: f.context).progress(planUUID: plan.uuid)

        #expect(progress.settledPeriodCount == 3)
        #expect(progress.paidPrincipalMinorUnits == 10_000)
        #expect(progress.remainingPrincipalMinorUnits == 0)
        #expect(progress.settledInterestMinorUnits == 300)
        #expect(progress.nextDuePeriod == nil)
        #expect(progress.plan.status == .completed)
    }

    @Test func 计划不存在或已软删抛错() throws {
        let f = try makeFixture()
        let provider = InstallmentPlanProvider(context: f.context)
        #expect(throws: InstallmentPlanProviderError.planNotFound) {
            _ = try provider.progress(planUUID: UUID())
        }

        let plan = try makePlan(f)
        try InstallmentService(context: f.context).softDeletePlan(uuid: plan.uuid, at: date(2026, 8, 15))
        #expect(throws: InstallmentPlanProviderError.planNotFound) {
            _ = try provider.progress(planUUID: plan.uuid)
        }
    }

    @Test func 历史坏数据聚合溢出时明确失败() throws {
        let f = try makeFixture()
        let plan = InstallmentPlan(
            name: "异常计划", kind: .purchase, accountID: f.card.uuid,
            ledgerID: f.ledger.uuid, principalMinorUnits: 1, totalPeriods: 2,
            amortizationKind: .flatFee, firstDueAt: date(2026, 8, 10)
        )
        f.context.insert(plan)
        for index in 1...2 {
            let period = InstallmentPeriod(
                planID: plan.uuid, periodIndex: index, dueAt: date(2026, 8, 9 + index),
                principalMinorUnits: Int.max, interestMinorUnits: 0
            )
            period.statusRawValue = InstallmentPeriodStatus.settled.rawValue
            f.context.insert(period)
        }
        try f.context.save()

        #expect(throws: MoneyArithmeticError.overflow) {
            _ = try InstallmentPlanProvider(context: f.context).progress(planUUID: plan.uuid)
        }
    }
}
