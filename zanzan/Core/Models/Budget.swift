import Foundation
import SwiftData

/// 预算——模板行（periodYear/periodMonth 为 nil）+ 按月实体行（数据库设计文档 5.7）。
/// 已用额由投影器实时汇总，不落库；金额以本位币计。
@Model
final class Budget {
    /// 业务主键，表间弱引用一律指向它
    var uuid: UUID = UUID()
    var ledgerID: UUID = UUID() // 预算必挂账本，init 注入
    /// nil = 总预算；非 nil → 支出侧父分类
    var categoryID: UUID? = nil
    var periodYear: Int? = nil  // nil = 模板行
    var periodMonth: Int? = nil // 与 periodYear 同空同有（命令层保证）
    /// 预算额度
    var amountMinorUnits: Int = 0
    /// 软删除标记，全库无硬删除
    var isSoftDeleted: Bool = false
    /// 创建时间
    var createdAt: Date = Date.now
    /// 最后修改时间（命令层维护）
    var updatedAt: Date = Date.now

    init(ledgerID: UUID, amountMinorUnits: Int) {
        self.ledgerID = ledgerID
        self.amountMinorUnits = amountMinorUnits
    }
}
