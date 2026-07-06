import Foundation
import SwiftData

/// 周期记账——规则字段 + 类型化模板字段（数据库设计文档 5.11）。
/// 管「无本金概念的重复模板流水」，与分期计划互不依赖。
@Model
final class StoredRecurringRule {
    /// 业务主键，表间弱引用一律指向它
    var uuid: UUID = UUID()
    // 规则
    /// 计划名
    var name: String = ""
    /// daily / weekly / monthly
    var frequencyRawValue: String = ""
    /// 间隔（每 n 天/周/月）
    var interval: Int = 1
    var recurrenceDays: [Int] = [] // 值大于当月天数时取月末（命令层实现）
    /// 生效起点
    var startAt: Date = Date.now
    /// 截止（nil = 无限期）
    var endAt: Date? = nil
    /// 下次生成时间
    var nextRunAt: Date = Date.now
    /// 暂停
    var isPaused: Bool = false
    // 模板（TransactionDraft 的持久化子集）
    /// 生成流水的类型
    var templateKindRawValue: String = ""
    var templateLedgerID: UUID? = nil // 命令层保证非空，与流水 ledgerID 同口径
    /// 金额
    var templateAmountMinorUnits: Int = 0
    /// 账户（转账时为转出方）
    var templateAccountID: UUID? = nil
    /// 转账转入方（templateKind == transfer 时必填，否则 nil）
    var templateTargetAccountID: UUID? = nil
    /// 分类
    var templateCategoryID: UUID? = nil
    /// 预设标签（房租/工资等周期账常配固定标签）
    var templateTagIDs: [UUID] = []
    /// 备注
    var templateNote: String = ""
    // 通用
    /// 软删除标记，全库无硬删除
    var isSoftDeleted: Bool = false
    /// 创建时间
    var createdAt: Date = Date.now
    /// 最后修改时间（命令层维护）
    var updatedAt: Date = Date.now

    var frequency: RecurrenceFrequency? { RecurrenceFrequency(rawValue: frequencyRawValue) }
    var templateKind: TransactionKind? { TransactionKind(rawValue: templateKindRawValue) }

    init(
        name: String,
        frequency: RecurrenceFrequency,
        startAt: Date,
        nextRunAt: Date,
        templateKind: TransactionKind,
        templateAmountMinorUnits: Int
    ) {
        self.name = name
        self.frequencyRawValue = frequency.rawValue
        self.startAt = startAt
        self.nextRunAt = nextRunAt
        self.templateKindRawValue = templateKind.rawValue
        self.templateAmountMinorUnits = templateAmountMinorUnits
    }
}
