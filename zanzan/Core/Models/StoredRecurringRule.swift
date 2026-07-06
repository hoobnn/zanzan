import Foundation
import SwiftData

/// 周期记账——规则字段 + 类型化模板字段（数据库设计文档 5.11）。
/// 管「无本金概念的重复模板流水」，与分期计划互不依赖。
@Model
final class StoredRecurringRule {
    var uuid: UUID = UUID()
    // 规则
    var name: String = ""
    var frequencyRawValue: String = ""
    var interval: Int = 1
    var recurrenceDays: [Int] = [] // 值大于当月天数时取月末（命令层实现）
    var startAt: Date = Date.now
    var endAt: Date? = nil
    var nextRunAt: Date = Date.now
    var isPaused: Bool = false
    // 模板（TransactionDraft 的持久化子集）
    var templateKindRawValue: String = ""
    var templateLedgerID: UUID? = nil // 命令层保证非空，与流水 ledgerID 同口径
    var templateAmountMinorUnits: Int = 0
    var templateAccountID: UUID? = nil
    var templateTargetAccountID: UUID? = nil
    var templateCategoryID: UUID? = nil
    var templateTagIDs: [UUID] = []
    var templateNote: String = ""
    // 通用
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
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
