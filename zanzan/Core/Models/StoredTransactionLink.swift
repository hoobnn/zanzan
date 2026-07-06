import Foundation
import SwiftData

/// 流水关联——报销/退款分摊，一行 = 一次分摊，M:N（数据库设计文档 5.5）。
/// 双向反查各建一索引。
@Model
final class StoredTransactionLink {
    #Index<StoredTransactionLink>([\.originalTransactionID], [\.settlementTransactionID])

    var uuid: UUID = UUID()
    var originalTransactionID: UUID = UUID()
    var settlementTransactionID: UUID = UUID()
    var kindRawValue: String = ""
    var amountMinorUnits: Int = 0 // 本次分摊金额，以原单币种计
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
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
