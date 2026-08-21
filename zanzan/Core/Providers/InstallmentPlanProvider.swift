import Foundation
import SwiftData

/// 单个分期计划的执行进度（设计文档 5.9 派生值：全部现算、不落库）。
struct InstallmentPlanProgress {
    let plan: InstallmentPlan
    let totalPeriods: Int
    /// 逐期已还（settled）期数
    let settledPeriodCount: Int
    /// 逐期已还本金（settled 期本金之和）
    let settledPrincipalMinorUnits: Int
    /// 提前结清覆盖的本金（cancelled 期本金之和，由结清转账一次付清）
    let earlySettledPrincipalMinorUnits: Int
    /// 剩余本金（pending 期本金之和）
    let remainingPrincipalMinorUnits: Int
    /// 已还利息（settled 期利息之和；结清违约金在流水 fee，不在期表口径内）
    let settledInterestMinorUnits: Int
    /// 剩余应付利息（pending 期利息之和；未到期利息不计入负债，仅作日程展示）
    let remainingInterestMinorUnits: Int
    /// 下一期应还（期序最小的 pending 期）；无待还期为 nil
    let nextDuePeriod: InstallmentPeriod?

    /// 已还本金合计 = 逐期已还 + 提前结清覆盖；恒有 已还 + 剩余 == 计划总本金
    let paidPrincipalMinorUnits: Int
}

/// 分期计划进度只读投影：进度口径完全由期表状态派生，
/// 与账户余额（欠款真相）解耦——删光计划不影响净资产（设计文档 §10 裁决 12）。
struct InstallmentPlanProvider {
    let context: ModelContext

    func progress(planUUID: UUID) throws -> InstallmentPlanProgress {
        let planDescriptor = FetchDescriptor<InstallmentPlan>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == planUUID }
        )
        guard let plan = try context.fetch(planDescriptor).first else {
            throw InstallmentPlanProviderError.planNotFound
        }
        let periods = try context.fetch(FetchDescriptor<InstallmentPeriod>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.planID == planUUID },
            sortBy: [SortDescriptor(\.periodIndex)]
        ))

        var settledCount = 0
        var settledPrincipal = 0
        var settledInterest = 0
        var cancelledPrincipal = 0
        var pendingPrincipal = 0
        var pendingInterest = 0
        var nextDue: InstallmentPeriod?
        for period in periods {
            switch period.status {
            case .settled:
                settledCount += 1
                settledPrincipal = try MoneyArithmetic.add(
                    settledPrincipal, period.principalMinorUnits
                )
                settledInterest = try MoneyArithmetic.add(
                    settledInterest, period.interestMinorUnits
                )
            case .cancelled:
                cancelledPrincipal = try MoneyArithmetic.add(
                    cancelledPrincipal, period.principalMinorUnits
                )
            case .pending:
                pendingPrincipal = try MoneyArithmetic.add(
                    pendingPrincipal, period.principalMinorUnits
                )
                pendingInterest = try MoneyArithmetic.add(
                    pendingInterest, period.interestMinorUnits
                )
                if nextDue == nil { nextDue = period } // 已按期序升序
            case nil:
                continue // 状态未知（前向兼容）：剔除精确统计，不计入任何口径
            }
        }

        return InstallmentPlanProgress(
            plan: plan,
            totalPeriods: plan.totalPeriods,
            settledPeriodCount: settledCount,
            settledPrincipalMinorUnits: settledPrincipal,
            earlySettledPrincipalMinorUnits: cancelledPrincipal,
            remainingPrincipalMinorUnits: pendingPrincipal,
            settledInterestMinorUnits: settledInterest,
            remainingInterestMinorUnits: pendingInterest,
            nextDuePeriod: nextDue,
            paidPrincipalMinorUnits: try MoneyArithmetic.add(
                settledPrincipal, cancelledPrincipal
            )
        )
    }
}

enum InstallmentPlanProviderError: LocalizedError, Equatable {
    case planNotFound

    var errorDescription: String? {
        switch self {
        case .planNotFound: ZanzanLocalization.string( "分期计划不存在")
        }
    }
}
