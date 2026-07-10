import Foundation
import SwiftData

/// 分期/贷款合同（数据库设计文档 5.9）。余额记已发生事实，计划只记日程与进度；
/// 已还期数/剩余本金/应付总利息全部由期表派生，不落库。
@Model
final class InstallmentPlan {
    #Index<InstallmentPlan>([\.uuid])

    /// 业务主键，表间弱引用一律指向它
    var uuid: UUID = UUID()
    /// 计划名（如「iPhone 24 期」「房贷」）
    var name: String = ""
    /// purchase（消费分期）/ statement（账单分期）/ loan（贷款）
    var kindRawValue: String = ""
    var accountID: UUID = UUID() // 债务账户：分期→credit，贷款→payable（命令层校验）
    var ledgerID: UUID = UUID()  // 产出还款流水的归属账本
    /// 本金总额（分）
    var principalMinorUnits: Int = 0
    /// 总期数
    var totalPeriods: Int = 0
    var annualRateBps: Int? = nil // 固定手续费类分期为 nil
    /// 还款方式：annuity / linearPrincipal / interestOnly / flatFee / custom（见 5.10 生成规则）
    var amortizationKindRawValue: String = ""
    /// 首期还款日
    var firstDueAt: Date = Date.now
    /// 到期自动生成还款流水；false = 仅提醒、用户确认后生成
    var isAutoSettle: Bool = false
    /// active / completed / settledEarly
    var statusRawValue: String = "active"
    /// 完结/提前结清时间
    var closedAt: Date? = nil
    /// 备注
    var note: String = ""
    /// 软删除标记，全库无硬删除
    var isSoftDeleted: Bool = false
    /// 创建时间
    var createdAt: Date = Date.now
    /// 最后修改时间（命令层维护）
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
