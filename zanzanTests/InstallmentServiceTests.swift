import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct InstallmentServiceTests {
    // MARK: - 夹具

    private enum InjectedSaveError: Error, Equatable {
        case failed
    }

    private struct Fixture {
        let context: ModelContext
        let ledger: Ledger
        let cash: Account     // fund：还款资金账户
        let card: Account     // credit：分期债务账户
        let mortgage: Account // payable：贷款债务账户
    }

    /// 固定 UTC 日历 + 固定日期，测试全程无 .now
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
        let mortgage = Account(name: "房贷", kind: .payable)
        context.insert(cash)
        context.insert(card)
        context.insert(mortgage)
        try context.save()
        return Fixture(context: context, ledger: ledger, cash: cash, card: card, mortgage: mortgage)
    }

    /// 10000 分 / 3 期 / 每期固定手续费 100 分——除不尽尾差标准用例
    private func flatFeeDraft(
        _ f: Fixture, principal: Int = 10_000, periods: Int = 3, feePerPeriod: Int = 100
    ) -> InstallmentPlanDraft {
        var draft = InstallmentPlanDraft(firstDueAt: date(2026, 8, 10))
        draft.name = "iPhone 分期"
        draft.kind = .purchase
        draft.accountID = f.card.uuid
        draft.ledgerID = f.ledger.uuid
        draft.principalMinorUnits = principal
        draft.totalPeriods = periods
        draft.amortizationKind = .flatFee
        draft.flatFeePerPeriodMinorUnits = feePerPeriod
        return draft
    }

    private func apply(
        _ preset: InstallmentCalculationPreset,
        to draft: inout InstallmentPlanDraft
    ) {
        let rules = preset.rules
        draft.chargeCollectionKind = rules.chargeCollectionKind
        draft.principalRoundingKind = rules.principalRoundingKind
        draft.principalRemainderKind = rules.principalRemainderKind
        draft.chargeRoundingKind = rules.chargeRoundingKind
        draft.chargeRemainderKind = rules.chargeRemainderKind
    }

    private func periods(of plan: InstallmentPlan, in context: ModelContext) throws -> [InstallmentPeriod] {
        let planID = plan.uuid
        return try context.fetch(FetchDescriptor<InstallmentPeriod>(
            predicate: #Predicate { $0.planID == planID },
            sortBy: [SortDescriptor(\.periodIndex)]
        ))
    }

    // MARK: - 创建计划与期表生成

    @Test func 创建flatFee计划物化全量期表() throws {
        let f = try makeFixture()
        let plan = try InstallmentService(context: f.context)
            .createPlan(flatFeeDraft(f), calendar: calendar)
        #expect(plan.status == .active)
        #expect(plan.annualRateBps == nil)

        let rows = try periods(of: plan, in: f.context)
        #expect(rows.count == 3)
        #expect(rows.map(\.periodIndex) == [1, 2, 3])
        let allPending = rows.allSatisfy { $0.status == .pending && $0.settledTransactionID == nil }
        #expect(allPending)
        #expect(rows.map(\.interestMinorUnits) == [100, 100, 100]) // 固定手续费逐期物化
        // 到期日自首期起逐月推进
        #expect(rows.map(\.dueAt) == [date(2026, 8, 10), date(2026, 9, 10), date(2026, 10, 10)])
    }

    @Test func 本金守恒_除不尽尾差归末期() throws {
        let f = try makeFixture()
        let plan = try InstallmentService(context: f.context)
            .createPlan(flatFeeDraft(f), calendar: calendar) // 10000 / 3
        let rows = try periods(of: plan, in: f.context)
        #expect(rows.map(\.principalMinorUnits) == [3_333, 3_333, 3_334]) // 尾差归末期（5.9）
        #expect(rows.reduce(0) { $0 + $1.principalMinorUnits } == 10_000)  // Σ 期本金 == 总本金
    }

    @Test func 工行首尾差与首期一次息费按规则物化() throws {
        let f = try makeFixture()
        let service = InstallmentService(context: f.context)

        var perPeriodDraft = flatFeeDraft(f)
        perPeriodDraft.flatFeePerPeriodMinorUnits = nil
        perPeriodDraft.totalChargeMinorUnits = 100
        apply(.icbcPerPeriod, to: &perPeriodDraft)
        let perPeriodPlan = try service.createPlan(perPeriodDraft, calendar: calendar)
        let perPeriodRows = try periods(of: perPeriodPlan, in: f.context)
        #expect(perPeriodRows.map(\.principalMinorUnits) == [3_334, 3_333, 3_333])
        #expect(perPeriodRows.map(\.interestMinorUnits) == [34, 33, 33])

        var upfrontDraft = flatFeeDraft(f)
        upfrontDraft.name = "工行首期收取"
        upfrontDraft.flatFeePerPeriodMinorUnits = nil
        upfrontDraft.totalChargeMinorUnits = 100
        apply(.icbcUpfront, to: &upfrontDraft)
        let upfrontPlan = try service.createPlan(upfrontDraft, calendar: calendar)
        let upfrontRows = try periods(of: upfrontPlan, in: f.context)
        #expect(upfrontRows.map(\.principalMinorUnits) == [3_334, 3_333, 3_333])
        #expect(upfrontRows.map(\.interestMinorUnits) == [100, 0, 0])
    }

    @Test func 农行元位取整示例保持本息费各自守恒() throws {
        let f = try makeFixture()
        var draft = flatFeeDraft(f, principal: 10_100)
        draft.flatFeePerPeriodMinorUnits = nil
        draft.totalChargeMinorUnits = 100
        apply(.abc, to: &draft)
        let plan = try InstallmentService(context: f.context).createPlan(draft, calendar: calendar)

        let rows = try periods(of: plan, in: f.context)
        #expect(rows.map(\.principalMinorUnits) == [3_400, 3_400, 3_300])
        #expect(rows.map(\.interestMinorUnits) == [33, 33, 34])
        #expect(rows.reduce(0) { $0 + $1.principalMinorUnits } == 10_100)
        #expect(rows.reduce(0) { $0 + $1.interestMinorUnits } == 100)
    }

    @Test func 等额本息期表_利息按剩余本金月利率_月供恒定() throws {
        let f = try makeFixture()
        var draft = flatFeeDraft(f, principal: 30_000, periods: 3)
        draft.kind = .loan
        draft.accountID = f.mortgage.uuid
        draft.amortizationKind = .annuity
        draft.annualRateBps = 1_200 // 年 12% → 月 1%
        draft.flatFeePerPeriodMinorUnits = nil
        let plan = try InstallmentService(context: f.context).createPlan(draft, calendar: calendar)

        let rows = try periods(of: plan, in: f.context)
        // 月供 = 30000×0.01×1.01³/(1.01³−1) ≈ 10200.66 → 10201；手算金表
        #expect(rows.map(\.principalMinorUnits) == [9_901, 10_000, 10_099])
        #expect(rows.map(\.interestMinorUnits) == [300, 201, 101])
        #expect(rows.reduce(0) { $0 + $1.principalMinorUnits } == 30_000) // 本金守恒
        // 前 n−1 期月供（本金+利息）恒定，末期承担取整尾差
        #expect(rows[0].principalMinorUnits + rows[0].interestMinorUnits == 10_201)
        #expect(rows[1].principalMinorUnits + rows[1].interestMinorUnits == 10_201)
    }

    @Test func 等额本金期表_本金均分利息递减() throws {
        let f = try makeFixture()
        var draft = flatFeeDraft(f, principal: 30_000, periods: 3)
        draft.kind = .loan
        draft.accountID = f.mortgage.uuid
        draft.amortizationKind = .linearPrincipal
        draft.annualRateBps = 1_200
        draft.flatFeePerPeriodMinorUnits = nil
        let plan = try InstallmentService(context: f.context).createPlan(draft, calendar: calendar)

        let rows = try periods(of: plan, in: f.context)
        #expect(rows.map(\.principalMinorUnits) == [10_000, 10_000, 10_000])
        #expect(rows.map(\.interestMinorUnits) == [300, 200, 100]) // 剩余本金 × 月利率
    }

    @Test func 等额本息零利率退化为本金均分() throws {
        let f = try makeFixture()
        var draft = flatFeeDraft(f, principal: 10_000, periods: 3)
        draft.amortizationKind = .annuity
        draft.annualRateBps = 0
        draft.flatFeePerPeriodMinorUnits = nil
        let plan = try InstallmentService(context: f.context).createPlan(draft, calendar: calendar)

        let rows = try periods(of: plan, in: f.context)
        #expect(rows.map(\.principalMinorUnits) == [3_333, 3_333, 3_334])
        #expect(rows.map(\.interestMinorUnits) == [0, 0, 0])
    }

    @Test func 先息后本纯息期可生成零本金息费流水() throws {
        let f = try makeFixture()
        var draft = flatFeeDraft(f)
        draft.kind = .loan
        draft.accountID = f.mortgage.uuid
        draft.amortizationKind = .interestOnly
        draft.annualRateBps = 1_200
        draft.flatFeePerPeriodMinorUnits = nil
        let service = InstallmentService(context: f.context)
        let plan = try service.createPlan(draft, calendar: calendar)

        let rows = try periods(of: plan, in: f.context)
        #expect(rows.map(\.principalMinorUnits) == [0, 0, 10_000])
        #expect(rows.map(\.interestMinorUnits) == [100, 100, 100])

        let tx = try service.settlePeriod(
            planUUID: plan.uuid,
            periodIndex: 1,
            fromAccountID: f.cash.uuid,
            at: date(2026, 8, 10)
        )
        #expect(tx.amountMinorUnits == 0)
        #expect(tx.feeMinorUnits == 100)
        #expect(tx.balanceDeltaMinorUnits(for: f.cash.uuid) == -100)
        #expect(tx.balanceDeltaMinorUnits(for: f.mortgage.uuid) == 0)
        #expect(rows[0].status == .settled)
    }

    @Test func 极限本金与利率生成期表不发生整数溢出() throws {
        let f = try makeFixture()
        var draft = flatFeeDraft(
            f,
            principal: MoneyAmount.maxAbsoluteMinorUnits,
            periods: 1
        )
        draft.kind = .loan
        draft.accountID = f.mortgage.uuid
        draft.amortizationKind = .linearPrincipal
        draft.annualRateBps = DraftLimits.maxAnnualRateBps
        draft.flatFeePerPeriodMinorUnits = nil

        let plan = try InstallmentService(context: f.context).createPlan(draft, calendar: calendar)
        let row = try #require(try periods(of: plan, in: f.context).first)
        #expect(row.principalMinorUnits == MoneyAmount.maxAbsoluteMinorUnits)
        #expect(row.interestMinorUnits == 833_333_333_333_333)
    }

    @Test func custom期表照录() throws {
        let f = try makeFixture()
        var draft = flatFeeDraft(f, principal: 10_000, periods: 3)
        draft.amortizationKind = .custom
        draft.flatFeePerPeriodMinorUnits = nil
        draft.customPeriods = [
            .init(principalMinorUnits: 5_000, interestMinorUnits: 10),
            .init(principalMinorUnits: 3_000, interestMinorUnits: 0),
            .init(principalMinorUnits: 2_000, interestMinorUnits: 90),
        ]
        let plan = try InstallmentService(context: f.context).createPlan(draft, calendar: calendar)

        let rows = try periods(of: plan, in: f.context)
        #expect(rows.map(\.principalMinorUnits) == [5_000, 3_000, 2_000])
        #expect(rows.map(\.interestMinorUnits) == [10, 0, 90])
    }

    @Test func 债务账户类型不匹配阻断() throws {
        let f = try makeFixture()
        var draft = flatFeeDraft(f)
        draft.accountID = f.cash.uuid // 分期挂 fund 账户
        #expect(throws: InstallmentServiceError.accountKindMismatch) {
            try InstallmentService(context: f.context).createPlan(draft, calendar: self.calendar)
        }
        draft = flatFeeDraft(f)
        draft.kind = .loan
        draft.accountID = f.card.uuid // 贷款挂 credit 账户
        #expect(throws: InstallmentServiceError.accountKindMismatch) {
            try InstallmentService(context: f.context).createPlan(draft, calendar: self.calendar)
        }
    }

    @Test func 账本或账户不存在阻断() throws {
        let f = try makeFixture()
        var draft = flatFeeDraft(f)
        draft.ledgerID = UUID()
        #expect(throws: InstallmentServiceError.ledgerNotFound) {
            try InstallmentService(context: f.context).createPlan(draft, calendar: self.calendar)
        }
        draft = flatFeeDraft(f)
        draft.accountID = UUID()
        #expect(throws: InstallmentServiceError.accountNotFound) {
            try InstallmentService(context: f.context).createPlan(draft, calendar: self.calendar)
        }
    }

    @Test func 归档账本或不可记账债务账户阻断且零写入() throws {
        let f = try makeFixture()
        let service = InstallmentService(context: f.context)

        f.ledger.isArchived = true
        try f.context.save()
        #expect(throws: InstallmentServiceError.ledgerNotFound) {
            try service.createPlan(self.flatFeeDraft(f), calendar: self.calendar)
        }

        f.ledger.isArchived = false
        f.card.isSelectableForRecord = false
        try f.context.save()
        #expect(throws: InstallmentServiceError.accountNotFound) {
            try service.createPlan(self.flatFeeDraft(f), calendar: self.calendar)
        }
        #expect(try f.context.fetchCount(FetchDescriptor<InstallmentPlan>()) == 0)
        #expect(try f.context.fetchCount(FetchDescriptor<InstallmentPeriod>()) == 0)
    }

    @Test func 创建保存失败回滚新增计划与期表() throws {
        let f = try makeFixture()
        let service = InstallmentService(
            context: f.context,
            saveAction: { throw InjectedSaveError.failed }
        )

        #expect(throws: InjectedSaveError.failed) {
            try service.createPlan(self.flatFeeDraft(f), calendar: self.calendar)
        }
        #expect(try f.context.fetchCount(FetchDescriptor<InstallmentPlan>()) == 0)
        #expect(try f.context.fetchCount(FetchDescriptor<InstallmentPeriod>()) == 0)
    }

    @Test func 结算保存失败回滚流水与计划期状态() throws {
        let f = try makeFixture()
        let plan = try InstallmentService(context: f.context)
            .createPlan(flatFeeDraft(f), calendar: calendar)
        let service = InstallmentService(
            context: f.context,
            saveAction: { throw InjectedSaveError.failed }
        )

        #expect(throws: InjectedSaveError.failed) {
            try service.settlePeriod(
                planUUID: plan.uuid,
                periodIndex: 1,
                fromAccountID: f.cash.uuid,
                at: self.date(2026, 8, 10)
            )
        }
        #expect(plan.status == .active)
        #expect(plan.closedAt == nil)
        #expect(try periods(of: plan, in: f.context).allSatisfy { $0.status == .pending })
        #expect(try f.context.fetchCount(FetchDescriptor<Transaction>()) == 0)
    }

    @Test func 软删保存失败回滚计划与期表标记() throws {
        let f = try makeFixture()
        let plan = try InstallmentService(context: f.context)
            .createPlan(flatFeeDraft(f), calendar: calendar)
        let service = InstallmentService(
            context: f.context,
            saveAction: { throw InjectedSaveError.failed }
        )

        #expect(throws: InjectedSaveError.failed) {
            try service.softDeletePlan(uuid: plan.uuid, at: self.date(2026, 8, 15))
        }
        #expect(!plan.isSoftDeleted)
        #expect(try periods(of: plan, in: f.context).allSatisfy { !$0.isSoftDeleted })
    }

    @Test func 提前结清与三个撤销命令保存失败均回滚() throws {
        let earlyFixture = try makeFixture()
        let earlyPlan = try InstallmentService(context: earlyFixture.context)
            .createPlan(flatFeeDraft(earlyFixture), calendar: calendar)
        let failingEarlyService = InstallmentService(
            context: earlyFixture.context,
            saveAction: { throw InjectedSaveError.failed }
        )
        #expect(throws: InjectedSaveError.failed) {
            try failingEarlyService.settleEarly(
                planUUID: earlyPlan.uuid,
                fromAccountID: earlyFixture.cash.uuid,
                at: self.date(2026, 8, 10)
            )
        }
        #expect(earlyPlan.status == .active)
        #expect(earlyPlan.closedAt == nil)
        #expect(
            try periods(of: earlyPlan, in: earlyFixture.context)
                .allSatisfy { $0.status == .pending }
        )
        #expect(try earlyFixture.context.fetchCount(FetchDescriptor<Transaction>()) == 0)

        let undoPeriodFixture = try makeFixture()
        let undoPeriodService = InstallmentService(context: undoPeriodFixture.context)
        let undoPeriodPlan = try undoPeriodService.createPlan(
            flatFeeDraft(undoPeriodFixture),
            calendar: calendar
        )
        let periodTransaction = try undoPeriodService.settlePeriod(
            planUUID: undoPeriodPlan.uuid,
            periodIndex: 1,
            fromAccountID: undoPeriodFixture.cash.uuid,
            at: date(2026, 8, 10)
        )
        let failingUndoPeriodService = InstallmentService(
            context: undoPeriodFixture.context,
            saveAction: { throw InjectedSaveError.failed }
        )
        #expect(throws: InjectedSaveError.failed) {
            try failingUndoPeriodService.undoSettlePeriod(
                planUUID: undoPeriodPlan.uuid,
                periodIndex: 1,
                at: self.date(2026, 8, 11)
            )
        }
        #expect(!periodTransaction.isSoftDeleted)
        #expect(
            try periods(of: undoPeriodPlan, in: undoPeriodFixture.context).first?.status
                == .settled
        )

        let undoEarlyFixture = try makeFixture()
        let undoEarlyService = InstallmentService(context: undoEarlyFixture.context)
        let undoEarlyPlan = try undoEarlyService.createPlan(
            flatFeeDraft(undoEarlyFixture),
            calendar: calendar
        )
        let earlyTransaction = try undoEarlyService.settleEarly(
            planUUID: undoEarlyPlan.uuid,
            fromAccountID: undoEarlyFixture.cash.uuid,
            at: date(2026, 8, 10)
        )
        let failingUndoEarlyService = InstallmentService(
            context: undoEarlyFixture.context,
            saveAction: { throw InjectedSaveError.failed }
        )
        #expect(throws: InjectedSaveError.failed) {
            try failingUndoEarlyService.undoSettleEarly(
                planUUID: undoEarlyPlan.uuid,
                at: self.date(2026, 8, 11)
            )
        }
        #expect(!earlyTransaction.isSoftDeleted)
        #expect(undoEarlyPlan.status == .settledEarly)
        #expect(
            try periods(of: undoEarlyPlan, in: undoEarlyFixture.context)
                .allSatisfy { $0.status == .cancelled }
        )

        let restoreFixture = try makeFixture()
        let restoreService = InstallmentService(context: restoreFixture.context)
        let restorePlan = try restoreService.createPlan(
            flatFeeDraft(restoreFixture),
            calendar: calendar
        )
        try restoreService.softDeletePlan(
            uuid: restorePlan.uuid,
            at: date(2026, 8, 10)
        )
        let failingRestoreService = InstallmentService(
            context: restoreFixture.context,
            saveAction: { throw InjectedSaveError.failed }
        )
        #expect(throws: InjectedSaveError.failed) {
            try failingRestoreService.undoSoftDeletePlan(
                uuid: restorePlan.uuid,
                at: self.date(2026, 8, 11)
            )
        }
        #expect(restorePlan.isSoftDeleted)
        #expect(
            try periods(of: restorePlan, in: restoreFixture.context)
                .allSatisfy(\.isSoftDeleted)
        )
    }

    @Test func 未知计划期状态与保留自动结算字段阻断写入() throws {
        let f = try makeFixture()
        let service = InstallmentService(context: f.context)
        let plan = try service.createPlan(flatFeeDraft(f), calendar: calendar)
        let rows = try periods(of: plan, in: f.context)

        plan.statusRawValue = "future-status"
        try f.context.save()
        #expect(throws: InstallmentServiceError.planStatusUnknown) {
            try service.settlePeriod(
                planUUID: plan.uuid,
                periodIndex: 1,
                fromAccountID: f.cash.uuid,
                at: self.date(2026, 8, 10)
            )
        }

        plan.statusRawValue = InstallmentPlanStatus.active.rawValue
        rows[1].statusRawValue = "future-period-status"
        try f.context.save()
        #expect(throws: InstallmentServiceError.periodStatusUnknown) {
            try service.settlePeriod(
                planUUID: plan.uuid,
                periodIndex: 1,
                fromAccountID: f.cash.uuid,
                at: self.date(2026, 8, 10)
            )
        }

        rows[1].statusRawValue = InstallmentPeriodStatus.pending.rawValue
        plan.isAutoSettle = true
        try f.context.save()
        #expect(throws: InstallmentServiceError.automaticSettlementUnsupported) {
            try service.settleEarly(
                planUUID: plan.uuid,
                fromAccountID: f.cash.uuid,
                at: self.date(2026, 8, 10)
            )
        }
        #expect(try f.context.fetchCount(FetchDescriptor<Transaction>()) == 0)
    }

    @Test func 未知摊还收取取整与尾差语义逐项阻断写入() throws {
        let f = try makeFixture()
        let service = InstallmentService(context: f.context)
        let plan = try service.createPlan(flatFeeDraft(f), calendar: calendar)
        let corruptions: [(Bool) -> Void] = [
            { invalid in
                plan.amortizationKindRawValue = invalid ? "future-amortization" : AmortizationKind.flatFee.rawValue
            },
            { invalid in
                plan.chargeCollectionKindRawValue = invalid ? "future-collection" : ChargeCollectionKind.perPeriod.rawValue
            },
            { invalid in
                plan.principalRoundingKindRawValue = invalid
                    ? "future-principal-rounding"
                    : InstallmentRoundingKind.downToMinorUnit.rawValue
            },
            { invalid in
                plan.principalRemainderKindRawValue = invalid
                    ? "future-principal-remainder"
                    : InstallmentRemainderKind.lastPeriod.rawValue
            },
            { invalid in
                plan.chargeRoundingKindRawValue = invalid
                    ? "future-charge-rounding"
                    : InstallmentRoundingKind.downToMinorUnit.rawValue
            },
            { invalid in
                plan.chargeRemainderKindRawValue = invalid
                    ? "future-charge-remainder"
                    : InstallmentRemainderKind.lastPeriod.rawValue
            },
        ]

        for corrupt in corruptions {
            corrupt(true)
            try f.context.save()
            #expect(throws: InstallmentServiceError.planCalculationRuleUnknown) {
                try service.settlePeriod(
                    planUUID: plan.uuid,
                    periodIndex: 1,
                    fromAccountID: f.cash.uuid,
                    at: self.date(2026, 8, 10)
                )
            }
            corrupt(false)
            try f.context.save()
        }
        #expect(try f.context.fetchCount(FetchDescriptor<Transaction>()) == 0)
    }

    @Test func 重复缺失期序与本金不守恒阻断写入() throws {
        let f = try makeFixture()
        let service = InstallmentService(context: f.context)
        let plan = try service.createPlan(flatFeeDraft(f), calendar: calendar)
        let rows = try periods(of: plan, in: f.context)

        rows[1].periodIndex = 1
        try f.context.save()
        #expect(throws: InstallmentServiceError.periodSequenceInvalid) {
            try service.settlePeriod(
                planUUID: plan.uuid,
                periodIndex: 1,
                fromAccountID: f.cash.uuid,
                at: self.date(2026, 8, 10)
            )
        }

        rows[1].periodIndex = 2
        rows[2].isSoftDeleted = true
        try f.context.save()
        #expect(throws: InstallmentServiceError.periodSequenceInvalid) {
            try service.settleEarly(
                planUUID: plan.uuid,
                fromAccountID: f.cash.uuid,
                at: self.date(2026, 8, 10)
            )
        }

        rows[2].isSoftDeleted = false
        rows[2].principalMinorUnits += 1
        try f.context.save()
        #expect(throws: InstallmentServiceError.periodPrincipalMismatch) {
            try service.softDeletePlan(uuid: plan.uuid, at: self.date(2026, 8, 10))
        }
        #expect(!plan.isSoftDeleted)
        #expect(try f.context.fetchCount(FetchDescriptor<Transaction>()) == 0)
    }

    @Test func 所有既有计划写命令共享计算语义完整性守卫() throws {
        let activeFixture = try makeFixture()
        let activeService = InstallmentService(context: activeFixture.context)
        let activePlan = try activeService.createPlan(
            flatFeeDraft(activeFixture),
            calendar: calendar
        )
        activePlan.chargeCollectionKindRawValue = "future-collection"
        try activeFixture.context.save()
        #expect(throws: InstallmentServiceError.planCalculationRuleUnknown) {
            try activeService.settlePeriod(
                planUUID: activePlan.uuid,
                periodIndex: 1,
                fromAccountID: activeFixture.cash.uuid,
                at: self.date(2026, 8, 10)
            )
        }
        #expect(throws: InstallmentServiceError.planCalculationRuleUnknown) {
            try activeService.settleEarly(
                planUUID: activePlan.uuid,
                fromAccountID: activeFixture.cash.uuid,
                at: self.date(2026, 8, 10)
            )
        }
        #expect(throws: InstallmentServiceError.planCalculationRuleUnknown) {
            try activeService.softDeletePlan(
                uuid: activePlan.uuid,
                at: self.date(2026, 8, 10)
            )
        }

        let periodFixture = try makeFixture()
        let periodService = InstallmentService(context: periodFixture.context)
        let periodPlan = try periodService.createPlan(flatFeeDraft(periodFixture), calendar: calendar)
        _ = try periodService.settlePeriod(
            planUUID: periodPlan.uuid,
            periodIndex: 1,
            fromAccountID: periodFixture.cash.uuid,
            at: date(2026, 8, 10)
        )
        periodPlan.chargeCollectionKindRawValue = "future-collection"
        try periodFixture.context.save()
        #expect(throws: InstallmentServiceError.planCalculationRuleUnknown) {
            try periodService.undoSettlePeriod(
                planUUID: periodPlan.uuid,
                periodIndex: 1,
                at: self.date(2026, 8, 11)
            )
        }

        let earlyFixture = try makeFixture()
        let earlyService = InstallmentService(context: earlyFixture.context)
        let earlyPlan = try earlyService.createPlan(flatFeeDraft(earlyFixture), calendar: calendar)
        _ = try earlyService.settleEarly(
            planUUID: earlyPlan.uuid,
            fromAccountID: earlyFixture.cash.uuid,
            at: date(2026, 8, 10)
        )
        earlyPlan.chargeCollectionKindRawValue = "future-collection"
        try earlyFixture.context.save()
        #expect(throws: InstallmentServiceError.planCalculationRuleUnknown) {
            try earlyService.undoSettleEarly(
                planUUID: earlyPlan.uuid,
                at: self.date(2026, 8, 11)
            )
        }

        let deletedFixture = try makeFixture()
        let deletedService = InstallmentService(context: deletedFixture.context)
        let deletedPlan = try deletedService.createPlan(flatFeeDraft(deletedFixture), calendar: calendar)
        try deletedService.softDeletePlan(uuid: deletedPlan.uuid, at: date(2026, 8, 10))
        deletedPlan.chargeCollectionKindRawValue = "future-collection"
        try deletedFixture.context.save()
        #expect(throws: InstallmentServiceError.planCalculationRuleUnknown) {
            try deletedService.undoSoftDeletePlan(
                uuid: deletedPlan.uuid,
                at: self.date(2026, 8, 11)
            )
        }
    }

    // MARK: - 记一期

    @Test func 记一期生成转账流水并推进期状态() throws {
        let f = try makeFixture()
        let service = InstallmentService(context: f.context)
        let plan = try service.createPlan(flatFeeDraft(f), calendar: calendar)
        let settledAt = date(2026, 8, 10)

        let tx = try service.settlePeriod(
            planUUID: plan.uuid, periodIndex: 1, fromAccountID: f.cash.uuid, at: settledAt
        )
        // 一期一笔转账：amount = 本金、fee = 利息（利息恒走 fee）
        #expect(tx.kind == .transfer)
        #expect(tx.amountMinorUnits == 3_333)
        #expect(tx.feeMinorUnits == 100)
        #expect(tx.account?.uuid == f.cash.uuid)
        #expect(tx.targetAccount?.uuid == f.card.uuid)
        #expect(tx.category == nil)
        #expect(tx.ledgerID == f.ledger.uuid)
        #expect(tx.occurredAt == settledAt)
        // 来源包指回计划
        #expect(tx.sourceKind == .installment)
        #expect(tx.sourceID == plan.uuid)

        let period = try #require(try periods(of: plan, in: f.context).first)
        #expect(period.status == .settled)
        #expect(period.settledAt == settledAt)
        #expect(period.settledTransactionID == tx.uuid)
        #expect(plan.status == .active) // 还有待还期，计划不完结
    }

    @Test func 记一期余额口径_资金减月供全额_债务只回补本金() throws {
        let f = try makeFixture()
        let service = InstallmentService(context: f.context)
        let plan = try service.createPlan(flatFeeDraft(f), calendar: calendar)
        let tx = try service.settlePeriod(
            planUUID: plan.uuid, periodIndex: 1, fromAccountID: f.cash.uuid, at: date(2026, 8, 10)
        )
        // fee 恒为流出方承担（5.4）：利息沉淀为支出，不进债务账户
        #expect(tx.balanceDeltaMinorUnits(for: f.cash.uuid) == -(3_333 + 100))
        #expect(tx.balanceDeltaMinorUnits(for: f.card.uuid) == 3_333)
    }

    @Test func 重复记同一期被阻断() throws {
        let f = try makeFixture()
        let service = InstallmentService(context: f.context)
        let plan = try service.createPlan(flatFeeDraft(f), calendar: calendar)
        _ = try service.settlePeriod(
            planUUID: plan.uuid, periodIndex: 1, fromAccountID: f.cash.uuid, at: date(2026, 8, 10)
        )
        #expect(throws: InstallmentServiceError.periodAlreadySettled) {
            try service.settlePeriod(
                planUUID: plan.uuid, periodIndex: 1, fromAccountID: f.cash.uuid, at: self.date(2026, 8, 11)
            )
        }
    }

    @Test func 禁止跳期且失败不改变期表状态() throws {
        let f = try makeFixture()
        let service = InstallmentService(context: f.context)
        let plan = try service.createPlan(flatFeeDraft(f), calendar: calendar)

        #expect(throws: InstallmentServiceError.mustSettleInOrder) {
            try service.settlePeriod(
                planUUID: plan.uuid,
                periodIndex: 2,
                fromAccountID: f.cash.uuid,
                at: self.date(2026, 8, 10)
            )
        }
        #expect(try periods(of: plan, in: f.context).allSatisfy { $0.status == .pending })
    }

    @Test func 从债务账户自身还款被拒() throws {
        let f = try makeFixture()
        let service = InstallmentService(context: f.context)
        let plan = try service.createPlan(flatFeeDraft(f), calendar: calendar)
        // 转出方 == 转入方，由 TransactionDraft 禁自转校验阻断（完整校验未被绕过的证据）
        #expect(throws: TransactionDraftError.self) {
            try service.settlePeriod(
                planUUID: plan.uuid, periodIndex: 1, fromAccountID: f.card.uuid, at: self.date(2026, 8, 10)
            )
        }
    }

    @Test func 记完全部期计划完结且不可再记() throws {
        let f = try makeFixture()
        let service = InstallmentService(context: f.context)
        let plan = try service.createPlan(flatFeeDraft(f), calendar: calendar)
        for index in 1...3 {
            _ = try service.settlePeriod(
                planUUID: plan.uuid, periodIndex: index, fromAccountID: f.cash.uuid, at: date(2026, 8, 10 + index)
            )
        }
        #expect(plan.status == .completed)
        #expect(plan.closedAt == date(2026, 8, 13)) // 末期实还时间

        // 完结后：不可再记期、不可再结清
        #expect(throws: InstallmentServiceError.planClosed) {
            try service.settlePeriod(
                planUUID: plan.uuid, periodIndex: 1, fromAccountID: f.cash.uuid, at: self.date(2026, 8, 14)
            )
        }
        #expect(throws: InstallmentServiceError.planClosed) {
            try service.settleEarly(
                planUUID: plan.uuid, fromAccountID: f.cash.uuid, at: self.date(2026, 8, 14)
            )
        }
    }

    // MARK: - 提前结清

    @Test func 提前结清生成结清流水并终结计划() throws {
        let f = try makeFixture()
        let service = InstallmentService(context: f.context)
        let plan = try service.createPlan(flatFeeDraft(f), calendar: calendar)
        _ = try service.settlePeriod(
            planUUID: plan.uuid, periodIndex: 1, fromAccountID: f.cash.uuid, at: date(2026, 8, 10)
        )
        let settledAt = date(2026, 8, 20)

        let tx = try service.settleEarly(
            planUUID: plan.uuid, fromAccountID: f.cash.uuid, penaltyMinorUnits: 500, at: settledAt
        )
        // 结清转账：amount = 剩余本金（3333 + 3334）、fee = 违约金
        #expect(tx.kind == .transfer)
        #expect(tx.amountMinorUnits == 6_667)
        #expect(tx.feeMinorUnits == 500)
        #expect(tx.targetAccount?.uuid == f.card.uuid)
        #expect(tx.sourceKind == .installment)
        #expect(tx.sourceID == plan.uuid)

        let rows = try periods(of: plan, in: f.context)
        #expect(rows[0].status == .settled) // 已记期为历史事实，不动
        #expect(rows[1].status == .cancelled)
        #expect(rows[2].status == .cancelled)
        #expect(rows[1].settledTransactionID == nil) // 取消期不回填流水
        #expect(plan.status == .settledEarly)
        #expect(plan.closedAt == settledAt)
    }

    @Test func 首期一次息费未付时提前结清仍计入结清费用() throws {
        let f = try makeFixture()
        var draft = flatFeeDraft(f)
        draft.flatFeePerPeriodMinorUnits = nil
        draft.totalChargeMinorUnits = 300
        apply(.icbcUpfront, to: &draft)
        let service = InstallmentService(context: f.context)
        let plan = try service.createPlan(draft, calendar: calendar)

        let tx = try service.settleEarly(
            planUUID: plan.uuid,
            fromAccountID: f.cash.uuid,
            penaltyMinorUnits: 500,
            at: date(2026, 8, 9)
        )
        #expect(tx.amountMinorUnits == 10_000)
        #expect(tx.feeMinorUnits == 800) // 违约金 500 + 尚未支付的首期一次息费 300
        #expect(try periods(of: plan, in: f.context).allSatisfy { $0.status == .cancelled })
    }

    @Test func 提前结清后再记期与重复结清均被阻断() throws {
        let f = try makeFixture()
        let service = InstallmentService(context: f.context)
        let plan = try service.createPlan(flatFeeDraft(f), calendar: calendar)
        _ = try service.settleEarly(planUUID: plan.uuid, fromAccountID: f.cash.uuid, at: date(2026, 8, 20))

        #expect(throws: InstallmentServiceError.planClosed) {
            try service.settlePeriod(
                planUUID: plan.uuid, periodIndex: 2, fromAccountID: f.cash.uuid, at: self.date(2026, 8, 21)
            )
        }
        #expect(throws: InstallmentServiceError.planClosed) {
            try service.settleEarly(planUUID: plan.uuid, fromAccountID: f.cash.uuid, at: self.date(2026, 8, 21))
        }
    }

    @Test func 结清违约金为负被拒() throws {
        let f = try makeFixture()
        let service = InstallmentService(context: f.context)
        let plan = try service.createPlan(flatFeeDraft(f), calendar: calendar)
        #expect(throws: InstallmentServiceError.negativePenalty) {
            try service.settleEarly(
                planUUID: plan.uuid, fromAccountID: f.cash.uuid, penaltyMinorUnits: -1, at: self.date(2026, 8, 20)
            )
        }
    }

    // MARK: - 撤销提前结清

    @Test func 撤销提前结清恢复结清前状态与进度闭环() throws {
        let f = try makeFixture()
        let service = InstallmentService(context: f.context)
        let plan = try service.createPlan(flatFeeDraft(f), calendar: calendar)
        let periodTx = try service.settlePeriod(
            planUUID: plan.uuid, periodIndex: 1, fromAccountID: f.cash.uuid, at: date(2026, 8, 10)
        )
        let settleTx = try service.settleEarly(
            planUUID: plan.uuid, fromAccountID: f.cash.uuid, penaltyMinorUnits: 500, at: date(2026, 8, 20)
        )

        try service.undoSettleEarly(planUUID: plan.uuid, at: date(2026, 8, 21))
        #expect(settleTx.isSoftDeleted) // 结清转账软删（可撤销），非硬删
        #expect(!periodTx.isSoftDeleted) // 已 settled 期流水为历史事实，不动
        #expect(plan.status == .active)
        #expect(plan.closedAt == nil)
        let rows = try periods(of: plan, in: f.context)
        #expect(rows.map(\.status) == [.settled, .pending, .pending]) // cancelled 全回 pending

        // 进度闭环恢复：已还 + 剩余 == 计划总本金，提前结清覆盖清零
        let progress = try InstallmentPlanProvider(context: f.context).progress(planUUID: plan.uuid)
        #expect(progress.settledPrincipalMinorUnits == 3_333)
        #expect(progress.earlySettledPrincipalMinorUnits == 0)
        #expect(progress.remainingPrincipalMinorUnits == 6_667)
        #expect(progress.paidPrincipalMinorUnits + progress.remainingPrincipalMinorUnits == 10_000)
    }

    @Test func 撤销提前结清后可继续记期() throws {
        let f = try makeFixture()
        let service = InstallmentService(context: f.context)
        let plan = try service.createPlan(flatFeeDraft(f), calendar: calendar)
        _ = try service.settleEarly(planUUID: plan.uuid, fromAccountID: f.cash.uuid, at: date(2026, 8, 20))
        try service.undoSettleEarly(planUUID: plan.uuid, at: date(2026, 8, 21))

        let tx = try service.settlePeriod(
            planUUID: plan.uuid, periodIndex: 1, fromAccountID: f.cash.uuid, at: date(2026, 8, 22)
        )
        #expect(tx.amountMinorUnits == 3_333)
        let period = try #require(try periods(of: plan, in: f.context).first)
        #expect(period.status == .settled)
        // 也可再次提前结清（撤销→再结清闭环）
        let tx2 = try service.settleEarly(planUUID: plan.uuid, fromAccountID: f.cash.uuid, at: date(2026, 8, 23))
        #expect(tx2.amountMinorUnits == 6_667)
        #expect(plan.status == .settledEarly)
    }

    @Test func 双重撤销与active计划撤销结清均被拒() throws {
        let f = try makeFixture()
        let service = InstallmentService(context: f.context)
        let plan = try service.createPlan(flatFeeDraft(f), calendar: calendar)
        #expect(throws: InstallmentServiceError.planNotSettledEarly) {
            try service.undoSettleEarly(planUUID: plan.uuid, at: self.date(2026, 8, 20)) // active 不可撤
        }
        _ = try service.settleEarly(planUUID: plan.uuid, fromAccountID: f.cash.uuid, at: date(2026, 8, 20))
        try service.undoSettleEarly(planUUID: plan.uuid, at: date(2026, 8, 21))
        #expect(throws: InstallmentServiceError.planNotSettledEarly) {
            try service.undoSettleEarly(planUUID: plan.uuid, at: self.date(2026, 8, 22)) // 双重撤销
        }
    }

    @Test func 结清流水已被软删时撤销结清仍解卡() throws {
        let f = try makeFixture()
        let service = InstallmentService(context: f.context)
        let plan = try service.createPlan(flatFeeDraft(f), calendar: calendar)
        let settleTx = try service.settleEarly(
            planUUID: plan.uuid, fromAccountID: f.cash.uuid, at: date(2026, 8, 20)
        )
        // 模拟历史坏数据：结清流水被越权软删
        settleTx.isSoftDeleted = true
        try f.context.save()

        try service.undoSettleEarly(planUUID: plan.uuid, at: date(2026, 8, 21))
        #expect(plan.status == .active) // 不因流水缺失而卡死
        let allPending = try periods(of: plan, in: f.context).allSatisfy { $0.status == .pending }
        #expect(allPending)
    }

    // MARK: - 撤销一期

    @Test func 撤销一期软删流水并回退期状态() throws {
        let f = try makeFixture()
        let service = InstallmentService(context: f.context)
        let plan = try service.createPlan(flatFeeDraft(f), calendar: calendar)
        let tx = try service.settlePeriod(
            planUUID: plan.uuid, periodIndex: 1, fromAccountID: f.cash.uuid, at: date(2026, 8, 10)
        )

        try service.undoSettlePeriod(planUUID: plan.uuid, periodIndex: 1, at: date(2026, 8, 11))
        #expect(tx.isSoftDeleted) // 期供流水软删（可撤销），非硬删
        let period = try #require(try periods(of: plan, in: f.context).first)
        #expect(period.status == .pending)
        #expect(period.settledAt == nil)
        #expect(period.settledTransactionID == nil)

        // 回退后可重新记该期（撤销→再记闭环）
        let tx2 = try service.settlePeriod(
            planUUID: plan.uuid, periodIndex: 1, fromAccountID: f.cash.uuid, at: date(2026, 8, 12)
        )
        #expect(tx2.uuid != tx.uuid)
        #expect(period.status == .settled)
    }

    @Test func 只能撤销最近一期且失败不改变已记状态() throws {
        let f = try makeFixture()
        let service = InstallmentService(context: f.context)
        let plan = try service.createPlan(flatFeeDraft(f), calendar: calendar)
        for index in 1...2 {
            _ = try service.settlePeriod(
                planUUID: plan.uuid,
                periodIndex: index,
                fromAccountID: f.cash.uuid,
                at: date(2026, 8, 10 + index)
            )
        }

        #expect(throws: InstallmentServiceError.mustUndoLatest) {
            try service.undoSettlePeriod(
                planUUID: plan.uuid,
                periodIndex: 1,
                at: self.date(2026, 8, 13)
            )
        }
        #expect(try periods(of: plan, in: f.context).map(\.status) == [.settled, .settled, .pending])

        try service.undoSettlePeriod(
            planUUID: plan.uuid,
            periodIndex: 2,
            at: date(2026, 8, 14)
        )
        #expect(try periods(of: plan, in: f.context).map(\.status) == [.settled, .pending, .pending])
    }

    @Test func 期供流水已被软删时撤销仍回退期状态_兜底解卡() throws {
        let f = try makeFixture()
        let service = InstallmentService(context: f.context)
        let plan = try service.createPlan(flatFeeDraft(f), calendar: calendar)
        let tx = try service.settlePeriod(
            planUUID: plan.uuid, periodIndex: 1, fromAccountID: f.cash.uuid, at: date(2026, 8, 10)
        )
        // 模拟历史坏数据：期供流水被通用入口越权软删（守卫加入前产生）
        tx.isSoftDeleted = true
        try f.context.save()

        try service.undoSettlePeriod(planUUID: plan.uuid, periodIndex: 1, at: date(2026, 8, 11))
        let period = try #require(try periods(of: plan, in: f.context).first)
        #expect(period.status == .pending) // 不因流水缺失而卡死
        #expect(period.settledTransactionID == nil)
    }

    @Test func 跨币种还款账户被明确阻断() throws {
        let f = try makeFixture()
        let usd = Account(name: "美元卡", kind: .fund)
        usd.currencyCode = "USD"
        f.context.insert(usd)
        try f.context.save()
        let service = InstallmentService(context: f.context)
        let plan = try service.createPlan(flatFeeDraft(f), calendar: calendar)
        // 期表以债务账户币种计，跨币种还款给明确错误而非误导性的缺到账金额
        #expect(throws: InstallmentServiceError.crossCurrencyRepaymentUnsupported) {
            _ = try service.settlePeriod(
                planUUID: plan.uuid, periodIndex: 1, fromAccountID: usd.uuid, at: date(2026, 8, 10)
            )
        }
    }

    @Test func 撤销末期使completed计划回到active() throws {
        let f = try makeFixture()
        let service = InstallmentService(context: f.context)
        let plan = try service.createPlan(flatFeeDraft(f), calendar: calendar)
        for index in 1...3 {
            _ = try service.settlePeriod(
                planUUID: plan.uuid, periodIndex: index, fromAccountID: f.cash.uuid, at: date(2026, 8, 10 + index)
            )
        }
        #expect(plan.status == .completed)

        try service.undoSettlePeriod(planUUID: plan.uuid, periodIndex: 3, at: date(2026, 8, 14))
        #expect(plan.status == .active)
        #expect(plan.closedAt == nil)
    }

    @Test func 提前结清后的已记期不可撤销() throws {
        let f = try makeFixture()
        let service = InstallmentService(context: f.context)
        let plan = try service.createPlan(flatFeeDraft(f), calendar: calendar)
        _ = try service.settlePeriod(
            planUUID: plan.uuid, periodIndex: 1, fromAccountID: f.cash.uuid, at: date(2026, 8, 10)
        )
        _ = try service.settleEarly(planUUID: plan.uuid, fromAccountID: f.cash.uuid, at: date(2026, 8, 20))

        // settledEarly 已终结：已记期与结清流水均为历史事实
        #expect(throws: InstallmentServiceError.planSettledEarlyLocked) {
            try service.undoSettlePeriod(planUUID: plan.uuid, periodIndex: 1, at: self.date(2026, 8, 21))
        }
    }

    @Test func 撤销未记的期被拒() throws {
        let f = try makeFixture()
        let service = InstallmentService(context: f.context)
        let plan = try service.createPlan(flatFeeDraft(f), calendar: calendar)
        #expect(throws: InstallmentServiceError.periodNotSettled) {
            try service.undoSettlePeriod(planUUID: plan.uuid, periodIndex: 1, at: self.date(2026, 8, 11))
        }
    }

    // MARK: - 软删计划

    @Test func 软删计划级联期行且流水不动_恢复连带期行() throws {
        let f = try makeFixture()
        let service = InstallmentService(context: f.context)
        let plan = try service.createPlan(flatFeeDraft(f), calendar: calendar)
        let tx = try service.settlePeriod(
            planUUID: plan.uuid, periodIndex: 1, fromAccountID: f.cash.uuid, at: date(2026, 8, 10)
        )

        try service.softDeletePlan(uuid: plan.uuid, at: date(2026, 8, 15))
        #expect(plan.isSoftDeleted)
        let rows = try periods(of: plan, in: f.context)
        let allPeriodsDeleted = rows.allSatisfy(\.isSoftDeleted)
        #expect(allPeriodsDeleted) // 级联软删期数行
        #expect(!tx.isSoftDeleted) // 已生成流水不动（历史事实）

        // 软删后不可再记期
        #expect(throws: InstallmentServiceError.planNotFound) {
            try service.settlePeriod(
                planUUID: plan.uuid, periodIndex: 2, fromAccountID: f.cash.uuid, at: self.date(2026, 8, 16)
            )
        }

        // 撤销恢复按相反方向：期行随主实体一并恢复
        try service.undoSoftDeletePlan(uuid: plan.uuid, at: date(2026, 8, 17))
        #expect(!plan.isSoftDeleted)
        let allPeriodsRestored = try periods(of: plan, in: f.context).allSatisfy { !$0.isSoftDeleted }
        #expect(allPeriodsRestored)
    }

    @Test func 恢复计划会先校验账本与债务账户() throws {
        let f = try makeFixture()
        let service = InstallmentService(context: f.context)
        let plan = try service.createPlan(flatFeeDraft(f), calendar: calendar)
        try service.softDeletePlan(uuid: plan.uuid, at: date(2026, 8, 15))

        f.ledger.isArchived = true
        try f.context.save()
        #expect(throws: InstallmentServiceError.ledgerNotFound) {
            try service.undoSoftDeletePlan(uuid: plan.uuid, at: self.date(2026, 8, 16))
        }
        #expect(plan.isSoftDeleted)
        #expect(try periods(of: plan, in: f.context).allSatisfy(\.isSoftDeleted))

        f.ledger.isArchived = false
        f.card.isArchived = true
        try f.context.save()
        #expect(throws: InstallmentServiceError.accountNotFound) {
            try service.undoSoftDeletePlan(uuid: plan.uuid, at: self.date(2026, 8, 17))
        }
        #expect(plan.isSoftDeleted)

        f.card.isArchived = false
        try f.context.save()
        try service.undoSoftDeletePlan(uuid: plan.uuid, at: date(2026, 8, 18))
        #expect(!plan.isSoftDeleted)
    }
}
