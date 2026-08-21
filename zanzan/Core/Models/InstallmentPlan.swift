import Foundation
import SwiftData

/// V1 历史快照。只用于迁移，字段不可再修改。
extension SchemaV1 {
    @Model
    final class InstallmentPlan {
        #Index<InstallmentPlan>([\.uuid])

        var uuid: UUID = UUID()
        var name: String = ""
        var kindRawValue: String = ""
        var accountID: UUID = UUID()
        var ledgerID: UUID = UUID()
        var principalMinorUnits: Int = 0
        var totalPeriods: Int = 0
        var annualRateBps: Int? = nil
        var amortizationKindRawValue: String = ""
        var firstDueAt: Date = Date.now
        var isAutoSettle: Bool = false
        var statusRawValue: String = "active"
        var closedAt: Date? = nil
        var note: String = ""
        var isSoftDeleted: Bool = false
        var createdAt: Date = Date.now
        var updatedAt: Date = Date.now

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
            kindRawValue = kind.rawValue
            self.accountID = accountID
            self.ledgerID = ledgerID
            self.principalMinorUnits = principalMinorUnits
            self.totalPeriods = totalPeriods
            amortizationKindRawValue = amortizationKind.rawValue
            self.firstDueAt = firstDueAt
        }
    }
}

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
    var accountID: UUID = UUID()
    var ledgerID: UUID = UUID()
    /// 本金总额（最小货币单位）
    var principalMinorUnits: Int = 0
    var totalPeriods: Int = 0
    var annualRateBps: Int? = nil
    var amortizationKindRawValue: String = ""
    /// 固定息费计划的息费总额；旧计划及按利率计算的计划为 nil，期表仍是唯一真相。
    var totalChargeMinorUnits: Int? = nil
    /// 息费逐期收取 / 首期一次收取。
    var chargeCollectionKindRawValue: String = "perPeriod"
    /// 本金和息费各自的取整、尾差规则。
    var principalRoundingKindRawValue: String = "downToMinorUnit"
    var principalRemainderKindRawValue: String = "lastPeriod"
    var chargeRoundingKindRawValue: String = "downToMinorUnit"
    var chargeRemainderKindRawValue: String = "lastPeriod"
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
    var chargeCollectionKind: ChargeCollectionKind? {
        ChargeCollectionKind(rawValue: chargeCollectionKindRawValue)
    }
    var principalRoundingKind: InstallmentRoundingKind? {
        InstallmentRoundingKind(rawValue: principalRoundingKindRawValue)
    }
    var principalRemainderKind: InstallmentRemainderKind? {
        InstallmentRemainderKind(rawValue: principalRemainderKindRawValue)
    }
    var chargeRoundingKind: InstallmentRoundingKind? {
        InstallmentRoundingKind(rawValue: chargeRoundingKindRawValue)
    }
    var chargeRemainderKind: InstallmentRemainderKind? {
        InstallmentRemainderKind(rawValue: chargeRemainderKindRawValue)
    }
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
        kindRawValue = kind.rawValue
        self.accountID = accountID
        self.ledgerID = ledgerID
        self.principalMinorUnits = principalMinorUnits
        self.totalPeriods = totalPeriods
        amortizationKindRawValue = amortizationKind.rawValue
        self.firstDueAt = firstDueAt
    }
}
