import Foundation
import SwiftData

/// 账户余额检查点——可整体重建的缓存，删光重算逐分一致（数据库设计文档 5.13）
@Model
final class StoredBalanceSnapshot {
    #Index<StoredBalanceSnapshot>([\.accountID, \.snapshotAt])

    var uuid: UUID = UUID()
    var accountID: UUID = UUID()
    var snapshotAt: Date = Date.now
    var balanceMinorUnits: Int = 0 // 账户币种计
    var fxRateToBase: Decimal? = nil // 快照时点汇率；CNY 账户为 nil
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(accountID: UUID, snapshotAt: Date, balanceMinorUnits: Int) {
        self.accountID = accountID
        self.snapshotAt = snapshotAt
        self.balanceMinorUnits = balanceMinorUnits
    }
}
