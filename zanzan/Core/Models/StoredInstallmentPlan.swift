import Foundation
import SwiftData

/// 分期/贷款合同（数据库设计文档 5.9）。余额记已发生事实，计划只记日程与进度；
/// 已还期数/剩余本金/应付总利息全部由期表派生，不落库。
@Model
final class StoredInstallmentPlan {
    #Index<StoredInstallmentPlan>([\.uuid])

    var uuid: UUID = UUID()
    var name: String = ""
    var kindRawValue: String = ""
    var accountID: UUID = UUID() // 债务账户：分期→credit，贷款→payable（命令层校验）
    var ledgerID: UUID = UUID()  // 产出还款流水的归属账本
    var principalMinorUnits: Int = 0
    var totalPeriods: Int = 0
    var annualRateBps: Int? = nil // 固定手续费类分期为 nil
    var amortizationKindRawValue: String = ""
    var firstDueAt: Date = Date.now
    var isAutoSettle: Bool = false
    var statusRawValue: String = "active"
    var closedAt: Date? = nil
    var note: String = ""
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    var kind: InstallmentPlanKind? { InstallmentPlanKind(rawValue: kindRawValue) }
    var amortizationKind: AmortizationKind? { AmortizationKind(rawValue: amortizationKindRawValue) }
    var status: InstallmentPlanStatus? { InstallmentPlanStatus(rawValue: statusRawValue) }

    init(
        name: String,
        kind: InstallmentPlanKind,
        accountID: UUID,
        ledgerID: UUID,
        principalMinorUnits: Int,
        totalPeriods: Int,
        amortizationKind: AmortizationKind,
        firstDueAt: Date
    ) {
        self.name = name
        self.kindRawValue = kind.rawValue
        self.accountID = accountID
        self.ledgerID = ledgerID
        self.principalMinorUnits = principalMinorUnits
        self.totalPeriods = totalPeriods
        self.amortizationKindRawValue = amortizationKind.rawValue
        self.firstDueAt = firstDueAt
    }
}
