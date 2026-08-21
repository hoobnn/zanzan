import Foundation
import SwiftData

/// 分期/贷款写路径命令（设计文档 5.9/5.10）。
///
/// 不变量：
/// - 建计划一次性物化全量期表，按计划保存的取整/尾差规则保证本金与息费守恒；
/// - 每期还款经 TransactionService 转账入口生成**一笔** transfer（amount = 该期本金、
///   fee = 该期利息，fee 恒为流出方承担），打 sourceKind = installment / sourceID = plan.uuid；
/// - 已记的期不可重复记；计划完结（completed / settledEarly）后不可再记期、不可再结清；
/// - 提前结清：剩余 pending 期置 cancelled，生成一笔结清转账（amount = 剩余本金、fee = 违约金）；
/// - 撤销一期：软删该期流水、期行回 pending；settledEarly 计划的已记期为历史事实不可撤销；
/// - 软删计划级联软删期数行，已生成流水不动（历史事实）；恢复按相反方向连带恢复期行。
///
/// 金额落库全为 Int 最小货币单位；可能溢出的乘除使用 Decimal 或 checked arithmetic。
/// 业务时间一律由调用方注入（at:），本层不取 .now。
struct InstallmentService {
    let context: ModelContext
    private let saveAction: (() throws -> Void)?

    init(context: ModelContext, saveAction: (() throws -> Void)? = nil) {
        self.context = context
        self.saveAction = saveAction
    }

    // MARK: - 创建计划

    /// 创建计划并按 amortizationKind 一次性生成全量期数表；到期日自 firstDueAt 起逐月推进。
    @discardableResult
    func createPlan(_ draft: InstallmentPlanDraft, calendar: Calendar = .current) throws -> InstallmentPlan {
        let v = try draft.validated()
        try ensureActiveLedger(v.ledgerID)
        let account = try fetchActiveAccount(v.accountID)
        try ensureAccountKindMatches(planKind: v.kind, account: account)

        let schedule = try makeSchedule(v)
        let datedSchedule = try schedule.enumerated().map { offset, amount in
            guard let dueAt = calendar.date(byAdding: .month, value: offset, to: v.firstDueAt),
                  DraftLimits.occurredAtRange.contains(dueAt) else {
                throw InstallmentServiceError.invalidDueDate
            }
            return (amount, dueAt)
        }
        let plan = InstallmentPlan(
            name: v.name,
            kind: v.kind,
            accountID: v.accountID,
            ledgerID: v.ledgerID,
            principalMinorUnits: v.principalMinorUnits,
            totalPeriods: v.totalPeriods,
            amortizationKind: v.amortizationKind,
            firstDueAt: v.firstDueAt
        )
        plan.annualRateBps = v.annualRateBps
        plan.totalChargeMinorUnits = v.totalChargeMinorUnits
        plan.chargeCollectionKindRawValue = v.chargeCollectionKind.rawValue
        plan.principalRoundingKindRawValue = v.principalRoundingKind.rawValue
        plan.principalRemainderKindRawValue = v.principalRemainderKind.rawValue
        plan.chargeRoundingKindRawValue = v.chargeRoundingKind.rawValue
        plan.chargeRemainderKindRawValue = v.chargeRemainderKind.rawValue
        plan.isAutoSettle = v.isAutoSettle
        plan.note = v.note
        context.insert(plan)

        for (offset, item) in datedSchedule.enumerated() {
            context.insert(InstallmentPeriod(
                planID: plan.uuid,
                periodIndex: offset + 1,
                dueAt: item.1,
                principalMinorUnits: item.0.principal,
                interestMinorUnits: item.0.interest
            ))
        }
        try saveChanges()
        return plan
    }

    // MARK: - 记一期

    /// 记一期：生成一笔转账（资金账户 → 债务账户，amount = 本金、fee = 利息），
    /// 期行置 settled 并回填流水；全部期记完自动置计划 completed。
    @discardableResult
    func settlePeriod(
        planUUID: UUID, periodIndex: Int, fromAccountID: UUID, at settledAt: Date
    ) throws -> Transaction {
        let plan = try fetchPlan(planUUID, includeDeleted: false)
        let periods = try validateScheduleIntegrity(plan: plan)
        guard plan.status == .active else { throw InstallmentServiceError.planClosed }
        let period = try fetchPeriod(planUUID: planUUID, periodIndex: periodIndex)
        switch period.status {
        case .pending: break
        case .settled: throw InstallmentServiceError.periodAlreadySettled
        case .cancelled: throw InstallmentServiceError.periodCancelled
        case nil: throw InstallmentServiceError.periodStatusUnknown
        }
        // 在暂存流水前完成所有可能失败的读取，避免后续读取异常把半成品留在上下文中。
        guard periods.first(where: { $0.status == .pending })?.uuid == period.uuid else {
            throw InstallmentServiceError.mustSettleInOrder
        }

        let tx = try recordTransfer(
            amountMinorUnits: period.principalMinorUnits,
            feeMinorUnits: period.interestMinorUnits,
            fromAccountID: fromAccountID,
            plan: plan,
            note: "\(plan.name) 第\(periodIndex)/\(plan.totalPeriods)期",
            occurredAt: settledAt
        )
        period.statusRawValue = InstallmentPeriodStatus.settled.rawValue
        period.settledAt = settledAt
        period.settledTransactionID = tx.uuid
        period.updatedAt = settledAt

        // 状态过滤在内存执行：本期刚改 settled 尚未落库，谓词按库中旧值判断会误算
        let stillPending = periods.contains { $0.status == .pending }
        if !stillPending {
            plan.statusRawValue = InstallmentPlanStatus.completed.rawValue
            plan.closedAt = settledAt
        }
        plan.updatedAt = settledAt
        try saveChanges()
        return tx
    }

    // MARK: - 提前结清

    /// 提前结清：剩余 pending 期全部置 cancelled，生成一笔结清转账
    /// （amount = 剩余本金合计、fee = 结清违约金），计划置 settledEarly 终结。
    @discardableResult
    func settleEarly(
        planUUID: UUID, fromAccountID: UUID, penaltyMinorUnits: Int = 0, at settledAt: Date
    ) throws -> Transaction {
        guard penaltyMinorUnits >= 0 else {
            throw InstallmentServiceError.negativePenalty
        }
        guard penaltyMinorUnits <= MoneyAmount.maxAbsoluteMinorUnits else {
            throw InstallmentServiceError.amountOverflow
        }
        let plan = try fetchPlan(planUUID, includeDeleted: false)
        let periods = try validateScheduleIntegrity(plan: plan)
        guard plan.status == .active else { throw InstallmentServiceError.planClosed }
        let pending = periods.filter { $0.status == .pending }
        guard !pending.isEmpty else { throw InstallmentServiceError.nothingToSettle }

        let remainingPrincipal = try checkedSum(pending.map(\.principalMinorUnits))
        let unpaidUpfrontCharge = plan.chargeCollectionKind == .upfrontFirstPeriod
            ? pending.first(where: { $0.periodIndex == 1 })?.interestMinorUnits ?? 0
            : 0
        let fee = try checkedSum([penaltyMinorUnits, unpaidUpfrontCharge])
        let tx = try recordTransfer(
            amountMinorUnits: remainingPrincipal,
            feeMinorUnits: fee,
            fromAccountID: fromAccountID,
            plan: plan,
            note: "\(plan.name) 提前结清",
            occurredAt: settledAt
        )
        for period in pending {
            period.statusRawValue = InstallmentPeriodStatus.cancelled.rawValue
            period.updatedAt = settledAt
        }
        plan.statusRawValue = InstallmentPlanStatus.settledEarly.rawValue
        plan.closedAt = settledAt
        plan.updatedAt = settledAt
        try saveChanges()
        return tx
    }

    /// 撤销提前结清（§4 撤销按相反方向执行）：软删结清转账、cancelled 期全部回 pending、
    /// 计划回 active 并清空 closedAt。提前结清后终态锁在位、不可能再有新记期，
    /// 撤销即回到结清前状态；已 settled 期为历史事实不受影响。
    func undoSettleEarly(planUUID: UUID, at undoneAt: Date) throws {
        let plan = try fetchPlan(planUUID, includeDeleted: false)
        let periods = try validateScheduleIntegrity(plan: plan)
        guard plan.status == .settledEarly else {
            throw InstallmentServiceError.planNotSettledEarly
        }

        // 结清转账 = 计划来源流水中未被任何 settled 期回填引用的那笔
        // （期供流水都记录在 period.settledTransactionID，结清转账无期行指回）；
        // 参照 undoSettlePeriod 兜底写法：流水已删/缺失不卡死，仍回退状态解卡
        let periodTxIDs = Set(periods.compactMap(\.settledTransactionID))
        let installmentRaw = TransactionSourceKind.installment.rawValue
        let planTransactions = try context.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate {
                !$0.isSoftDeleted && $0.sourceID == planUUID && $0.sourceKindRawValue == installmentRaw
            }
        ))
        for tx in planTransactions where !periodTxIDs.contains(tx.uuid) {
            tx.isSoftDeleted = true
            tx.updatedAt = undoneAt
            try invalidateSnapshots(for: tx)
        }

        for period in periods where period.status == .cancelled {
            period.statusRawValue = InstallmentPeriodStatus.pending.rawValue
            period.updatedAt = undoneAt
        }
        plan.statusRawValue = InstallmentPlanStatus.active.rawValue
        plan.closedAt = nil
        plan.updatedAt = undoneAt
        try saveChanges()
    }

    // MARK: - 撤销一期

    /// 撤销一期：软删该期流水、期行回 pending；completed 计划随之回 active。
    /// settledEarly 计划已终结（已记期与结清流水均为历史事实），不允许回退。
    func undoSettlePeriod(planUUID: UUID, periodIndex: Int, at undoneAt: Date) throws {
        let plan = try fetchPlan(planUUID, includeDeleted: false)
        let periods = try validateScheduleIntegrity(plan: plan)
        switch plan.status {
        case .active, .completed: break
        case .settledEarly: throw InstallmentServiceError.planSettledEarlyLocked
        case nil: throw InstallmentServiceError.planClosed
        }
        let period = try fetchPeriod(planUUID: planUUID, periodIndex: periodIndex)
        guard period.status == .settled, let txID = period.settledTransactionID else {
            throw InstallmentServiceError.periodNotSettled
        }
        guard periods.last(where: { $0.status == .settled })?.uuid == period.uuid else {
            throw InstallmentServiceError.mustUndoLatest
        }

        // 期供流水由本服务全权管理（TransactionService 对 installment 来源已阻断通用删改）；
        // 流水已软删或缺失时仍回退期状态，兜底解卡历史坏数据
        if let tx = try context.fetch(
            FetchDescriptor<Transaction>(predicate: #Predicate { $0.uuid == txID })
        ).first, !tx.isSoftDeleted {
            tx.isSoftDeleted = true
            tx.updatedAt = undoneAt
            try invalidateSnapshots(for: tx)
        }
        period.statusRawValue = InstallmentPeriodStatus.pending.rawValue
        period.settledAt = nil
        period.settledTransactionID = nil
        period.updatedAt = undoneAt
        if plan.status == .completed {
            plan.statusRawValue = InstallmentPlanStatus.active.rawValue
            plan.closedAt = nil
        }
        plan.updatedAt = undoneAt
        try saveChanges()
    }

    // MARK: - 软删计划

    /// 软删计划：级联软删期数行；已生成的流水不动（历史事实，设计文档 §4）。
    func softDeletePlan(uuid: UUID, at deletedAt: Date) throws {
        let plan = try fetchPlan(uuid, includeDeleted: false)
        let periods = try validateScheduleIntegrity(plan: plan)
        plan.isSoftDeleted = true
        plan.updatedAt = deletedAt
        for period in periods {
            period.isSoftDeleted = true
            period.updatedAt = deletedAt
        }
        try saveChanges()
    }

    /// 撤销软删：按相反方向恢复，级联软删的期行随主实体一并恢复（设计文档 §4）。
    func undoSoftDeletePlan(uuid: UUID, at restoredAt: Date) throws {
        let plan = try fetchPlan(uuid, includeDeleted: true)
        guard plan.isSoftDeleted else { return }
        let periods = try validateScheduleIntegrity(plan: plan, includeDeleted: true)
        try ensureActiveLedger(plan.ledgerID)
        let account = try fetchActiveAccount(plan.accountID)
        let kind = try requirePlanKind(plan)
        try ensureAccountKindMatches(planKind: kind, account: account)
        plan.isSoftDeleted = false
        plan.updatedAt = restoredAt
        for period in periods where period.isSoftDeleted {
            period.isSoftDeleted = false
            period.updatedAt = restoredAt
        }
        try saveChanges()
    }

    // MARK: - 期表生成

    private struct PeriodAmount {
        let principal: Int
        let interest: Int
    }

    /// 按还款方式生成逐期本息（5.10 生成规则），生成后统一校验守恒与可执行性。
    private func makeSchedule(_ v: InstallmentPlanDraft.Validated) throws -> [PeriodAmount] {
        let schedule: [PeriodAmount]
        switch v.amortizationKind {
        case .annuity:
            schedule = annuitySchedule(
                principal: v.principalMinorUnits, periods: v.totalPeriods, annualRateBps: v.annualRateBps ?? 0
            )
        case .linearPrincipal:
            let rate = v.annualRateBps ?? 0
            var remaining = v.principalMinorUnits
            schedule = try distributedParts(
                total: v.principalMinorUnits,
                periods: v.totalPeriods,
                rounding: .downToMinorUnit,
                remainder: .lastPeriod
            ).map { part in
                let interest = monthlyInterest(onRemaining: remaining, annualRateBps: rate)
                remaining -= part
                return PeriodAmount(principal: part, interest: interest)
            }
        case .interestOnly:
            let interest = monthlyInterest(
                onRemaining: v.principalMinorUnits,
                annualRateBps: v.annualRateBps ?? 0
            )
            schedule = (1...v.totalPeriods).map { index in
                PeriodAmount(
                    principal: index == v.totalPeriods ? v.principalMinorUnits : 0,
                    interest: interest
                )
            }
        case .flatFee:
            let principalParts = try distributedParts(
                total: v.principalMinorUnits,
                periods: v.totalPeriods,
                rounding: v.principalRoundingKind,
                remainder: v.principalRemainderKind
            )
            let chargeParts: [Int]
            if v.chargeCollectionKind == .upfrontFirstPeriod {
                chargeParts = [v.totalChargeMinorUnits ?? 0]
                    + Array(repeating: 0, count: v.totalPeriods - 1)
            } else {
                chargeParts = try distributedParts(
                    total: v.totalChargeMinorUnits ?? 0,
                    periods: v.totalPeriods,
                    rounding: v.chargeRoundingKind,
                    remainder: v.chargeRemainderKind
                )
            }
            schedule = zip(principalParts, chargeParts)
                .map { PeriodAmount(principal: $0.0, interest: $0.1) }
        case .custom:
            schedule = v.customPeriods.map {
                PeriodAmount(principal: $0.principalMinorUnits, interest: $0.interestMinorUnits)
            }
        }

        let principalTotal = try checkedSum(schedule.map(\.principal))
        let chargeTotal = try checkedSum(schedule.map(\.interest))
        let expectedChargeTotal = v.amortizationKind == .flatFee ? v.totalChargeMinorUnits : nil
        let executable = schedule.allSatisfy {
            $0.interest >= 0
                && ($0.principal > 0
                    || (v.amortizationKind == .interestOnly && $0.interest > 0))
        }
        guard schedule.count == v.totalPeriods,
              principalTotal == v.principalMinorUnits,
              expectedChargeTotal == nil || chargeTotal == expectedChargeTotal,
              executable else {
            throw InstallmentServiceError.infeasibleSchedule
        }
        return schedule
    }

    /// 等额本息：月供经 Decimal（十进制定点，非二进制浮点）求解一次并取整，
    /// 逐期利息 = 剩余本金 × 月利率（整数四舍五入），逐期本金 = 月供 − 利息，末期本金 = 剩余全额（尾差归末期）。
    private func annuitySchedule(principal: Int, periods: Int, annualRateBps: Int) -> [PeriodAmount] {
        // 零利率退化为本金均分、零利息
        guard annualRateBps > 0 else {
            let parts = try? distributedParts(
                total: principal,
                periods: periods,
                rounding: .downToMinorUnit,
                remainder: .lastPeriod
            )
            return (parts ?? []).map { PeriodAmount(principal: $0, interest: 0) }
        }
        let payment = annuityPaymentMinorUnits(principal: principal, periods: periods, annualRateBps: annualRateBps)
        var remaining = principal
        var schedule: [PeriodAmount] = []
        for index in 1...periods {
            let interest = monthlyInterest(onRemaining: remaining, annualRateBps: annualRateBps)
            let part = index == periods
                ? remaining // 尾差归末期（设计文档 5.9）
                : min(max(payment - interest, 0), remaining)
            schedule.append(PeriodAmount(principal: part, interest: interest))
            remaining -= part
        }
        return schedule
    }

    /// 等额本息月供 = P·r(1+r)ⁿ / ((1+r)ⁿ−1)，r = 月利率 = annualRateBps / 120000。
    private func annuityPaymentMinorUnits(principal: Int, periods: Int, annualRateBps: Int) -> Int {
        let r = Decimal(annualRateBps) / Decimal(BPS_PER_MONTH_DIVISOR)
        let factor = pow(1 + r, periods)
        var payment = Decimal(principal) * r * factor / (factor - 1)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &payment, 0, .plain)
        return (rounded as NSDecimalNumber).intValue
    }

    /// 总额分配：先按规则得到常规期金额，剩余一整期放到指定首/末期，保证逐单位守恒。
    private func distributedParts(
        total: Int,
        periods: Int,
        rounding: InstallmentRoundingKind,
        remainder: InstallmentRemainderKind
    ) throws -> [Int] {
        guard total >= 0, periods > 0 else { throw InstallmentServiceError.infeasibleSchedule }
        guard total > 0 else { return Array(repeating: 0, count: periods) }

        let unit = rounding == .nearestMajorUnit ? 100 : 1
        var average = Decimal(total) / Decimal(periods * unit)
        var rounded = Decimal()
        NSDecimalRound(
            &rounded,
            &average,
            0,
            rounding == .downToMinorUnit ? .down : .plain
        )
        let baseDecimal = rounded * Decimal(unit)
        guard baseDecimal >= 0,
              baseDecimal <= Decimal(MoneyAmount.maxAbsoluteMinorUnits) else {
            throw InstallmentServiceError.infeasibleSchedule
        }
        let base = (baseDecimal as NSDecimalNumber).intValue
        let (regularTotal, overflow) = base.multipliedReportingOverflow(by: periods - 1)
        guard !overflow, regularTotal <= total else {
            throw InstallmentServiceError.infeasibleSchedule
        }
        let remainderPart = total - regularTotal
        var parts = Array(repeating: base, count: periods)
        parts[remainder == .firstPeriod ? 0 : periods - 1] = remainderPart
        return parts
    }

    /// 当月利息 = 剩余本金 × 年利率(bps) / 120000，整数四舍五入。
    private func monthlyInterest(onRemaining remaining: Int, annualRateBps: Int) -> Int {
        guard annualRateBps > 0 else { return 0 }
        var value = Decimal(remaining) * Decimal(annualRateBps) / Decimal(BPS_PER_MONTH_DIVISOR)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .plain)
        return (rounded as NSDecimalNumber).intValue
    }

    private func checkedSum(_ values: [Int]) throws -> Int {
        try values.reduce(0) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(value)
            guard !overflow else { throw InstallmentServiceError.amountOverflow }
            return sum
        }
    }

    // MARK: - 流水生成

    /// 期供/结清转账统一入口：经 TransactionService 走完整校验（不绕过直写 Transaction），
    /// 仅暂存不保存，由 settlePeriod/settleEarly 连同期数与计划状态一次提交。
    private func recordTransfer(
        amountMinorUnits: Int, feeMinorUnits: Int, fromAccountID: UUID,
        plan: InstallmentPlan, note: String, occurredAt: Date
    ) throws -> Transaction {
        // 期表金额以债务账户币种计，跨币种还款的到账金额无法从期表派生——
        // 明确阻断（而非让 TransactionService 抛误导性的 missingTargetAmount）
        let fromAccount = try fetchActiveAccount(fromAccountID)
        let debtAccount = try fetchActiveAccount(plan.accountID)
        guard fromAccount.currencyCode == debtAccount.currencyCode else {
            throw InstallmentServiceError.crossCurrencyRepaymentUnsupported
        }
        var draft = TransactionDraft()
        draft.kind = .transfer
        draft.amountString = MoneyAmount.decimalString(fromMinorUnits: amountMinorUnits)
        if feeMinorUnits > 0 {
            draft.feeString = MoneyAmount.decimalString(fromMinorUnits: feeMinorUnits)
        }
        draft.occurredAt = occurredAt
        draft.note = note
        draft.accountUUID = fromAccountID
        draft.targetAccountUUID = plan.accountID
        return try TransactionService(context: context).stageTransaction(
            draft, ledgerID: plan.ledgerID, source: (kind: .installment, id: plan.uuid)
        )
    }

    private func invalidateSnapshots(for transaction: Transaction) throws {
        try BalanceSnapshotService.invalidateSnapshots(
            accountUUIDs: Set([
                transaction.account?.uuid,
                transaction.targetAccount?.uuid,
            ].compactMap { $0 }),
            onOrAfter: transaction.occurredAt,
            context: context
        )
    }

    /// 所有命令共用的保存边界。SwiftData 保存失败不会自动清空内存改动，
    /// 因此必须 rollback，避免调用方收到失败后脏对象又被后续保存带入数据库。
    private func saveChanges() throws {
        do {
            if let saveAction {
                try saveAction()
            } else {
                try context.zanzanSave()
            }
        } catch {
            context.rollback()
            throw error
        }
    }

    /// 写命令统一的前向兼容与期表完整性守卫。
    ///
    /// 未知语义只读；缺期、重期与本金不守恒均不得绕过后继续结算、撤销或软删。
    private func validateScheduleIntegrity(
        plan: InstallmentPlan,
        includeDeleted: Bool = false
    ) throws -> [InstallmentPeriod] {
        _ = try requirePlanKind(plan)
        guard plan.status != nil else {
            throw InstallmentServiceError.planStatusUnknown
        }
        guard plan.amortizationKind != nil,
              plan.chargeCollectionKind != nil,
              plan.principalRoundingKind != nil,
              plan.principalRemainderKind != nil,
              plan.chargeRoundingKind != nil,
              plan.chargeRemainderKind != nil else {
            throw InstallmentServiceError.planCalculationRuleUnknown
        }
        guard !plan.isAutoSettle else {
            throw InstallmentServiceError.automaticSettlementUnsupported
        }

        let periods = try fetchPeriods(
            planUUID: plan.uuid,
            includeDeleted: includeDeleted
        )
        guard plan.totalPeriods > 0,
              periods.count == plan.totalPeriods,
              periods.map(\.periodIndex) == Array(1...plan.totalPeriods) else {
            throw InstallmentServiceError.periodSequenceInvalid
        }
        guard periods.allSatisfy({
            $0.status != nil
                && $0.principalMinorUnits >= 0
                && $0.interestMinorUnits >= 0
        }) else {
            if periods.contains(where: { $0.status == nil }) {
                throw InstallmentServiceError.periodStatusUnknown
            }
            throw InstallmentServiceError.infeasibleSchedule
        }
        let principalTotal = try checkedSum(periods.map(\.principalMinorUnits))
        guard plan.principalMinorUnits > 0,
              principalTotal == plan.principalMinorUnits else {
            throw InstallmentServiceError.periodPrincipalMismatch
        }
        return periods
    }

    private func requirePlanKind(_ plan: InstallmentPlan) throws -> InstallmentPlanKind {
        guard let kind = plan.kind else {
            throw InstallmentServiceError.planKindUnknown
        }
        return kind
    }

    // MARK: - 查询辅助

    private func ensureActiveLedger(_ uuid: UUID) throws {
        let descriptor = FetchDescriptor<Ledger>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        )
        guard let ledger = try context.fetch(descriptor).first, !ledger.isArchived else {
            throw InstallmentServiceError.ledgerNotFound
        }
    }

    private func fetchActiveAccount(_ uuid: UUID) throws -> Account {
        let descriptor = FetchDescriptor<Account>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        )
        guard let account = try context.fetch(descriptor).first else {
            throw InstallmentServiceError.accountNotFound
        }
        guard !account.isArchived, account.isSelectableForRecord else {
            throw InstallmentServiceError.accountNotFound
        }
        return account
    }

    /// 债务账户类型匹配（5.9）：消费/账单分期 → credit；贷款 → payable。
    private func ensureAccountKindMatches(planKind: InstallmentPlanKind, account: Account) throws {
        let expected: AccountKind = switch planKind {
        case .purchase, .statement: .credit
        case .loan: .payable
        }
        guard account.kind == expected else { throw InstallmentServiceError.accountKindMismatch }
    }

    private func fetchPlan(_ uuid: UUID, includeDeleted: Bool) throws -> InstallmentPlan {
        let predicate: Predicate<InstallmentPlan> = includeDeleted
            ? #Predicate { $0.uuid == uuid }
            : #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        guard let plan = try context.fetch(FetchDescriptor<InstallmentPlan>(predicate: predicate)).first else {
            throw InstallmentServiceError.planNotFound
        }
        return plan
    }

    private func fetchPeriod(planUUID: UUID, periodIndex: Int) throws -> InstallmentPeriod {
        let descriptor = FetchDescriptor<InstallmentPeriod>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.planID == planUUID && $0.periodIndex == periodIndex }
        )
        guard let period = try context.fetch(descriptor).first else {
            throw InstallmentServiceError.periodNotFound
        }
        return period
    }

    private func fetchPeriods(planUUID: UUID, includeDeleted: Bool = false) throws -> [InstallmentPeriod] {
        let predicate: Predicate<InstallmentPeriod> = includeDeleted
            ? #Predicate { $0.planID == planUUID }
            : #Predicate { !$0.isSoftDeleted && $0.planID == planUUID }
        return try context.fetch(FetchDescriptor<InstallmentPeriod>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.periodIndex)]
        ))
    }
}

/// 年利率基点 → 月利率的除数：bps / 10000（化率）/ 12（化月）= bps / 120000。
private let BPS_PER_MONTH_DIVISOR = 120_000

enum InstallmentServiceError: LocalizedError, Equatable {
    case ledgerNotFound
    case accountNotFound
    case accountKindMismatch
    case planKindUnknown
    case planStatusUnknown
    case planCalculationRuleUnknown
    case automaticSettlementUnsupported
    case planNotFound
    case periodNotFound
    case planClosed
    case planSettledEarlyLocked
    case planNotSettledEarly
    case periodAlreadySettled
    case periodCancelled
    case periodStatusUnknown
    case periodSequenceInvalid
    case periodPrincipalMismatch
    case periodNotSettled
    case mustSettleInOrder
    case mustUndoLatest
    case nothingToSettle
    case negativePenalty
    case amountOverflow
    case infeasibleSchedule
    case invalidDueDate
    case crossCurrencyRepaymentUnsupported

    var errorDescription: String? {
        switch self {
        case .ledgerNotFound: ZanzanLocalization.string( "账本不存在或已删除")
        case .accountNotFound: ZanzanLocalization.string( "账户不存在或已删除")
        case .accountKindMismatch: ZanzanLocalization.string( "债务账户类型与计划类型不匹配（分期须挂信用账户，贷款须挂应付账户）")
        case .planKindUnknown: ZanzanLocalization.string( "计划类型无法识别，请升级应用后重试")
        case .planStatusUnknown: ZanzanLocalization.string( "计划状态无法识别，请升级应用后重试")
        case .planCalculationRuleUnknown: ZanzanLocalization.string( "分期计算规则无法识别，请升级应用后重试")
        case .automaticSettlementUnsupported: ZanzanLocalization.string( "当前版本尚不支持自动结算，请关闭后重试")
        case .planNotFound: ZanzanLocalization.string( "分期计划不存在")
        case .periodNotFound: ZanzanLocalization.string( "分期期数不存在")
        case .planClosed: ZanzanLocalization.string( "计划已完结，不可再操作期数")
        case .planSettledEarlyLocked: ZanzanLocalization.string( "计划已提前结清，已还期数不可撤销")
        case .planNotSettledEarly: ZanzanLocalization.string( "计划未提前结清，无可撤销的结清操作")
        case .periodAlreadySettled: ZanzanLocalization.string( "该期已还款，不可重复记")
        case .periodCancelled: ZanzanLocalization.string( "该期已随提前结清取消")
        case .periodStatusUnknown: ZanzanLocalization.string( "该期状态无法识别，请升级应用后重试")
        case .periodSequenceInvalid: ZanzanLocalization.string( "期数表不完整或期序重复，请修复后重试")
        case .periodPrincipalMismatch: ZanzanLocalization.string( "期数表本金合计与计划不一致，请修复后重试")
        case .periodNotSettled: ZanzanLocalization.string( "该期尚未还款，无可撤销的流水")
        case .mustSettleInOrder: ZanzanLocalization.string( "请先偿还最早的待还期数")
        case .mustUndoLatest: ZanzanLocalization.string( "只能从最近一笔还款开始撤销")
        case .nothingToSettle: ZanzanLocalization.string( "没有待还期数，无需结清")
        case .negativePenalty: ZanzanLocalization.string( "结清违约金不能为负")
        case .amountOverflow: ZanzanLocalization.string( "分期金额计算超出可支持范围")
        case .infeasibleSchedule: ZanzanLocalization.string( "期数表生成失败：本息拆分不成立")
        case .invalidDueDate: ZanzanLocalization.string( "无法推算应还日期")
        case .crossCurrencyRepaymentUnsupported: ZanzanLocalization.string( "还款账户需与分期账户同币种")
        }
    }
}
