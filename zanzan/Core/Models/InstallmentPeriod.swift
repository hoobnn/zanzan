import Foundation
import SwiftData

/// 分期期数——一期一行，建计划时全量物化（数据库设计文档 5.10）。
/// 期表行是唯一真相，amortizationKind 仅作再生成/展示元数据。
@Model
final class InstallmentPeriod {
    #Index<InstallmentPeriod>([\.planID, \.periodIndex])

    /// 业务主键，表间弱引用一律指向它
    var uuid: UUID = UUID()
    /// → InstallmentPlan.uuid
    var planID: UUID = UUID()
    var periodIndex: Int = 0 // 期序，1 起
    /// 应还日
    var dueAt: Date = Date.now
    /// 该期本金
    var principalMinorUnits: Int = 0
    /// 该期利息/手续费
    var interestMinorUnits: Int = 0
    /// pending / settled / cancelled（提前结清时未到期部分）
    var statusRawValue: String = "pending"
    /// 实还时间
    var settledAt: Date? = nil
    /// → 该期还款转账流水
    var settledTransactionID: UUID? = nil
    /// 软删除标记，全库无硬删除
    var isSoftDeleted: Bool = false
    /// 创建时间
    var createdAt: Date = Date.now
    /// 最后修改时间（命令层维护）
    var updatedAt: Date = Date.now

    var status: InstallmentPeriodStatus? { InstallmentPeriodStatus(rawValue: statusRawValue) }

    init(planID: UUID, periodIndex: Int, dueAt: Date, principalMinorUnits: Int, interestMinorUnits: Int) {
        self.planID = planID
        self.periodIndex = periodIndex
        self.dueAt = dueAt
        self.principalMinorUnits = principalMinorUnits
        self.interestMinorUnits = interestMinorUnits
    }
}
