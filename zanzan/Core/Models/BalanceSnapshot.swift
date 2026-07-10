import Foundation
import SwiftData

/// 账户余额检查点——可整体重建的缓存，删光重算逐分一致（数据库设计文档 5.13）
@Model
final class BalanceSnapshot {
    #Index<BalanceSnapshot>([\.accountID, \.snapshotAt])

    /// 业务主键，表间弱引用一律指向它
    var uuid: UUID = UUID()
    /// → Account.uuid
    var accountID: UUID = UUID()
    /// 快照时点（如每月末落一条）
    var snapshotAt: Date = Date.now
    var balanceMinorUnits: Int = 0 // 账户币种计
    var fxRateToBase: Decimal? = nil // 快照时点汇率；CNY 账户为 nil
    /// 软删除标记，全库无硬删除
    var isSoftDeleted: Bool = false
    /// 创建时间
    var createdAt: Date = Date.now
    /// 最后修改时间（命令层维护）
    var updatedAt: Date = Date.now

    init(accountID: UUID, snapshotAt: Date, balanceMinorUnits: Int) {
        self.accountID = accountID
        self.snapshotAt = snapshotAt
        self.balanceMinorUnits = balanceMinorUnits
    }
}
