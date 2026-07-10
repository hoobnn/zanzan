import Foundation
import SwiftData

/// 分期/贷款写路径命令（设计文档 5.9/5.10）。
///
/// 不变量：
/// - 建计划一次性物化全量期表，**取整尾差归末期**（5.9 明文），Σ 期本金 == 计划总本金；
/// - 每期还款经 TransactionService 转账入口生成**一笔** transfer（amount = 该期本金、
///   fee = 该期利息，fee 恒为流出方承担），打 sourceKind = installment / sourceID = plan.uuid；
/// - 已记的期不可重复记；计划完结（completed / settledEarly）后不可再记期、不可再结清；
/// - 提前结清：剩余 pending 期置 cancelled，生成一笔结清转账（amount = 剩余本金、fee = 违约金）；
/// - 撤销一期：软删该期流水、期行回 pending；settledEarly 计划的已记期为历史事实不可撤销；
/// - 软删计划级联软删期数行，已生成流水不动（历史事实）；恢复按相反方向连带恢复期行。
///
/// 金额全程 Int 分单位整数运算（整数除法 + 余数归末期）；业务时间一律由调用方注入（at:），
/// 本层不取 .now。
struct InstallmentService {
    let context: ModelContext

    // MARK: - 创建计划

    /// 创建计划并按 amortizationKind 一次性生成全量期数表；到期日自 firstDueAt 起逐月推进。
    @discardableResult
    func createPlan(_ draft: InstallmentPlanDraft, calendar: Calendar = .current) throws -> InstallmentPlan {
        let v = try draft.validated()
        try ensureActiveLedger(v.ledgerID)
        let account = try fetchActiveAccount(v.accountID)
        try ensureAccountKindMatches(planKind: v.kind, account: account)

        let schedule = try makeSchedule(v)
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
        plan.isAutoSettle = v.isAutoSettle
        plan.note = v.note
        context.insert(plan)

        for (offset, amount) in schedule.enumerated() {
            guard let dueAt = calendar.date(byAdding: .month, value: offset, to: v.firstDueAt) else {
                throw InstallmentServiceError.invalidDueDate
            }
            context.insert(InstallmentPeriod(
                planID: plan.uuid,
                periodIndex: offset + 1,
                dueAt: dueAt,
                principalMinorUnits: amount.principal,
                interestMinorUnits: amount.interest
            ))
        }
        try context.save()
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
        // 状态未知（前向兼容）与已完结一律按不可记期处理
        guard plan.status == .active else { throw InstallmentServiceError.planClosed }
        let period = try fetchPeriod(planUUID: planUUID, periodIndex: periodIndex)
        switch period.status {
        case .pending: break
        case .settled: throw InstallmentServiceError.periodAlreadySettled
        case .cancelled: throw InstallmentServiceError.periodCancelled
        case nil: throw InstallmentServiceError.periodStatusUnknown
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
        let stillPending = try fetchPeriods(planUUID: planUUID).contains { $0.status == .pending }
        if !stillPending {
            plan.statusRawValue = InstallmentPlanStatus.completed.rawValue
            plan.closedAt = settledAt
        }
        plan.updatedAt = settledAt
        try context.save()
        return tx
    }

    // MARK: - 提前结清

    /// 提前结清：剩余 pending 期全部置 cancelled，生成一笔结清转账
    /// （amount = 剩余本金合计、fee = 结清违约金），计划置 settledEarly 终结。
    @discardableResult
    func settleEarly(
        planUUID: UUID, fromAccountID: UUID, penaltyMinorUnits: Int = 0, at settledAt: Date
    ) throws -> Transaction {
        guard penaltyMinorUnits >= 0 else { throw InstallmentServiceError.negativePenalty }
        let plan = try fetchPlan(planUUID, includeDeleted: false)
        guard plan.status == .active else { throw InstallmentServiceError.planClosed }
        let pending = try fetchPeriods(planUUID: planUUID).filter { $0.status == .pending }
        guard !pending.isEmpty else { throw InstallmentServiceError.nothingToSettle }

        let remainingPrincipal = pending.reduce(0) { $0 + $1.principalMinorUnits }
        let tx = try recordTransfer(
            amountMinorUnits: remainingPrincipal,
            feeMinorUnits: penaltyMinorUnits,
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
        try context.save()
        return tx
    }

    // MARK: - 撤销一期

    /// 撤销一期：软删该期流水、期行回 pending；completed 计划随之回 active。
    /// settledEarly 计划已终结（已记期与结清流水均为历史事实），不允许回退。
    func undoSettlePeriod(planUUID: UUID, periodIndex: Int, at undoneAt: Date) throws {
        let plan = try fetchPlan(planUUID, includeDeleted: false)
        switch plan.status {
        case .active, .completed: break
        case .settledEarly: throw InstallmentServiceError.planSettledEarlyLocked
        case nil: throw InstallmentServiceError.planClosed
        }
        let period = try fetchPeriod(planUUID: planUUID, periodIndex: periodIndex)
        guard period.status == .settled, let txID = period.settledTransactionID else {
            throw InstallmentServiceError.periodNotSettled
        }

        // 期供流水由本服务全权管理（TransactionService 对 installment 来源已阻断通用删改）；
        // 流水已软删或缺失时仍回退期状态，兜底解卡历史坏数据
        if let tx = try context.fetch(
            FetchDescriptor<Transaction>(predicate: #Predicate { $0.uuid == txID })
        ).first, !tx.isSoftDeleted {
            tx.isSoftDeleted = true
            tx.updatedAt = undoneAt
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
        try context.save()
    }

    // MARK: - 软删计划

    /// 软删计划：级联软删期数行；已生成的流水不动（历史事实，设计文档 §4）。
    func softDeletePlan(uuid: UUID, at deletedAt: Date) throws {
        let plan = try fetchPlan(uuid, includeDeleted: false)
        plan.isSoftDeleted = true
        plan.updatedAt = deletedAt
        for period in try fetchPeriods(planUUID: uuid) {
            period.isSoftDeleted = true
            period.updatedAt = deletedAt
        }
        try context.save()
    }

    /// 撤销软删：按相反方向恢复，级联软删的期行随主实体一并恢复（设计文档 §4）。
    func undoSoftDeletePlan(uuid: UUID, at restoredAt: Date) throws {
        let plan = try fetchPlan(uuid, includeDeleted: true)
        plan.isSoftDeleted = false
        plan.updatedAt = restoredAt
        for period in try fetchPeriods(planUUID: uuid, includeDeleted: true) where period.isSoftDeleted {
            period.isSoftDeleted = false
            period.updatedAt = restoredAt
        }
        try context.save()
    }

    // MARK: - 期表生成

    private struct PeriodAmount {
        let principal: Int
        let interest: Int
    }

    /// 按还款方式生成逐期本息（5.10 生成规则），生成后统一后置校验：
    /// 本金守恒（Σ == 总本金）与可执行性（每期本金 ≥ 1 分、利息 ≥ 0）——金额路径双保险。
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
            schedule = evenPrincipalParts(principal: v.principalMinorUnits, periods: v.totalPeriods).map { part in
                let interest = monthlyInterest(onRemaining: remaining, annualRateBps: rate)
                remaining -= part
                return PeriodAmount(principal: part, interest: interest)
            }
        case .interestOnly:
            // Draft 已阻断（零本金期与 amount 恒正冲突）；此处防御
            throw InstallmentServiceError.infeasibleSchedule
        case .flatFee:
            let fee = v.flatFeePerPeriodMinorUnits ?? 0
            schedule = evenPrincipalParts(principal: v.principalMinorUnits, periods: v.totalPeriods)
                .map { PeriodAmount(principal: $0, interest: fee) }
        case .custom:
            schedule = v.customPeriods.map {
                PeriodAmount(principal: $0.principalMinorUnits, interest: $0.interestMinorUnits)
            }
        }

        guard
            schedule.count == v.totalPeriods,
            schedule.reduce(0, { $0 + $1.principal }) == v.principalMinorUnits,
            schedule.allSatisfy({ $0.principal >= 1 && $0.interest >= 0 })
        else { throw InstallmentServiceError.infeasibleSchedule }
        return schedule
    }

    /// 等额本息：月供经 Decimal（十进制定点，非二进制浮点）求解一次并取整，
    /// 逐期利息 = 剩余本金 × 月利率（整数四舍五入），逐期本金 = 月供 − 利息，末期本金 = 剩余全额（尾差归末期）。
    private func annuitySchedule(principal: Int, periods: Int, annualRateBps: Int) -> [PeriodAmount] {
        // 零利率退化为本金均分、零利息
        guard annualRateBps > 0 else {
            return evenPrincipalParts(principal: principal, periods: periods)
                .map { PeriodAmount(principal: $0, interest: 0) }
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

    /// 本金均分，除不尽的尾差归末期（设计文档 5.9：「取整尾差归末期」）。
    private func evenPrincipalParts(principal: Int, periods: Int) -> [Int] {
        let base = principal / periods
        var parts = Array(repeating: base, count: periods)
        parts[periods - 1] = principal - base * (periods - 1)
        return parts
    }

    /// 当月利息 = 剩余本金 × 年利率(bps) / 120000，整数四舍五入。
    private func monthlyInterest(onRemaining remaining: Int, annualRateBps: Int) -> Int {
        guard annualRateBps > 0 else { return 0 }
        return roundedDivide(remaining * annualRateBps, by: BPS_PER_MONTH_DIVISOR)
    }

    /// 非负整数四舍五入除法（金额路径全程整数，禁浮点）。
    private func roundedDivide(_ numerator: Int, by denominator: Int) -> Int {
        (numerator + denominator / 2) / denominator
    }

    // MARK: - 流水生成

    /// 期供/结清转账统一入口：经 TransactionService 走完整校验（不绕过直写 Transaction），
    /// 来源包经参数随首个 save 原子落库（崩溃不留无来源的孤儿转账）。
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
        return try TransactionService(context: context).recordTransaction(
            draft, ledgerID: plan.ledgerID, source: (kind: .installment, id: plan.uuid)
        )
    }

    // MARK: - 查询辅助

    private func ensureActiveLedger(_ uuid: UUID) throws {
        let count = try context.fetchCount(
            FetchDescriptor<Ledger>(predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid })
        )
        guard count > 0 else { throw InstallmentServiceError.ledgerNotFound }
    }

    private func fetchActiveAccount(_ uuid: UUID) throws -> Account {
        let descriptor = FetchDescriptor<Account>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        )
        guard let account = try context.fetch(descriptor).first else {
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
    case planNotFound
    case periodNotFound
    case planClosed
    case planSettledEarlyLocked
    case periodAlreadySettled
    case periodCancelled
    case periodStatusUnknown
    case periodNotSettled
    case nothingToSettle
    case negativePenalty
    case infeasibleSchedule
    case invalidDueDate
    case crossCurrencyRepaymentUnsupported

    var errorDescription: String? {
        switch self {
        case .ledgerNotFound: String(localized: "账本不存在或已删除")
        case .accountNotFound: String(localized: "账户不存在或已删除")
        case .accountKindMismatch: String(localized: "债务账户类型与计划类型不匹配（分期须挂信用账户，贷款须挂应付账户）")
        case .planNotFound: String(localized: "分期计划不存在")
        case .periodNotFound: String(localized: "分期期数不存在")
        case .planClosed: String(localized: "计划已完结，不可再操作期数")
        case .planSettledEarlyLocked: String(localized: "计划已提前结清，已还期数不可撤销")
        case .periodAlreadySettled: String(localized: "该期已还款，不可重复记")
        case .periodCancelled: String(localized: "该期已随提前结清取消")
        case .periodStatusUnknown: String(localized: "该期状态无法识别，请升级应用后重试")
        case .periodNotSettled: String(localized: "该期尚未还款，无可撤销的流水")
        case .nothingToSettle: String(localized: "没有待还期数，无需结清")
        case .negativePenalty: String(localized: "结清违约金不能为负")
        case .infeasibleSchedule: String(localized: "期数表生成失败：本息拆分不成立")
        case .invalidDueDate: String(localized: "无法推算应还日期")
        case .crossCurrencyRepaymentUnsupported: String(localized: "还款账户需与分期账户同币种")
        }
    }
}
