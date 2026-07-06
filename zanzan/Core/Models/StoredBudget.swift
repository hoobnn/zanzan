import Foundation
import SwiftData

/// 预算——模板行（periodYear/periodMonth 为 nil）+ 按月实体行（数据库设计文档 5.7）。
/// 已用额由投影器实时汇总，不落库；金额以本位币计。
@Model
final class StoredBudget {
    var uuid: UUID = UUID()
    var ledgerID: UUID = UUID() // 预算必挂账本，init 注入
    var categoryID: UUID? = nil // nil = 总预算
    var periodYear: Int? = nil  // nil = 模板行
    var periodMonth: Int? = nil // 与 periodYear 同空同有（命令层保证）
    var amountMinorUnits: Int = 0
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(ledgerID: UUID, amountMinorUnits: Int) {
        self.ledgerID = ledgerID
        self.amountMinorUnits = amountMinorUnits
    }
}
