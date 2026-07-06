import Foundation
import SwiftData

/// 流水关联——报销/退款分摊，一行 = 一次分摊，M:N（数据库设计文档 5.5）。
/// 双向反查各建一索引。
@Model
final class StoredTransactionLink {
    #Index<StoredTransactionLink>([\.originalTransactionID], [\.settlementTransactionID])

    /// 业务主键，表间弱引用一律指向它
    var uuid: UUID = UUID()
    /// → 原单（报销 = 垫付支出单；退款 = 原支出单）
    var originalTransactionID: UUID = UUID()
    /// → 到账单（报销打款/退款入账，kind 均为 income）
    var settlementTransactionID: UUID = UUID()
    /// reimbursement / refund
    var kindRawValue: String = ""
    var amountMinorUnits: Int = 0 // 本次分摊金额，以原单币种计
    /// 软删除标记，全库无硬删除
    var isSoftDeleted: Bool = false
    /// 创建时间
    var createdAt: Date = Date.now
    /// 最后修改时间（命令层维护）
    var updatedAt: Date = Date.now

    var kind: TransactionLinkKind? { TransactionLinkKind(rawValue: kindRawValue) }

    init(
        originalTransactionID: UUID,
        settlementTransactionID: UUID,
        kind: TransactionLinkKind,
        amountMinorUnits: Int
    ) {
        self.originalTransactionID = originalTransactionID
        self.settlementTransactionID = settlementTransactionID
        self.kindRawValue = kind.rawValue
        self.amountMinorUnits = amountMinorUnits
    }
}
