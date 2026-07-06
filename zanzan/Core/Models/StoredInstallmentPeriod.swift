import Foundation
import SwiftData

/// 分期期数——一期一行，建计划时全量物化（数据库设计文档 5.10）。
/// 期表行是唯一真相，amortizationKind 仅作再生成/展示元数据。
@Model
final class StoredInstallmentPeriod {
    #Index<StoredInstallmentPeriod>([\.planID, \.periodIndex])

    var uuid: UUID = UUID()
    var planID: UUID = UUID()
    var periodIndex: Int = 0 // 期序，1 起
    var dueAt: Date = Date.now
    var principalMinorUnits: Int = 0
    var interestMinorUnits: Int = 0
    var statusRawValue: String = "pending"
    var settledAt: Date? = nil
    var settledTransactionID: UUID? = nil
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
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
