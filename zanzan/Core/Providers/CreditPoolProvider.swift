import Foundation
import SwiftData

/// 授信池额度总览（设计文档 5.8：额度全部派生、不落库）。
struct CreditPoolOverview {
    let pool: CreditPool
    /// 池已用 = Σ 活跃成员卡欠款；溢缴款不释放池额度（裁决 9：正余额卡按欠款 0 计）
    let usedMinorUnits: Int

    var totalLimitMinorUnits: Int { pool.totalLimitMinorUnits }
    /// 池可用 = max(0, 总额度 − 池已用)
    var availableMinorUnits: Int { max(0, pool.totalLimitMinorUnits - usedMinorUnits) }
}

/// 授信池只读投影：池总额度/成员合计已用/剩余额度。
struct CreditPoolProvider {
    let context: ModelContext

    func overview(poolUUID: UUID) throws -> CreditPoolOverview {
        let poolDescriptor = FetchDescriptor<CreditPool>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == poolUUID }
        )
        guard let pool = try context.fetch(poolDescriptor).first else {
            throw CreditPoolProviderError.poolNotFound
        }
        let members = try context.fetch(
            FetchDescriptor<Account>(
                predicate: #Predicate { !$0.isSoftDeleted && $0.creditPoolID == poolUUID }
            )
        )
        let balanceProvider = AccountBalanceProvider(context: context)
        // 归档卡余额与统计照常（§4 归档语义），已用额度同样计入
        let used = try members.reduce(0) { sum, member in
            sum + max(0, -(try balanceProvider.balanceMinorUnits(of: member)))
        }
        return CreditPoolOverview(pool: pool, usedMinorUnits: used)
    }
}

enum CreditPoolProviderError: LocalizedError {
    case poolNotFound

    var errorDescription: String? {
        switch self {
        case .poolNotFound: String(localized: "授信池不存在或已删除")
        }
    }
}
