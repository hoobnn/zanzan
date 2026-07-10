import Foundation
import SwiftData

/// 外部汇率源接口（设计文档 §11：写入路径已就绪，接 API 零 schema 改动）。
/// 现阶段无网络实现——预填走 FxRateProvider 的流水快照字典；对接外部 API 后作为另一实现注入。
protocol ExchangeRateProviding {
    /// 1 单位 currencyCode 对本位币（CNY）的汇率；未知币种返回 nil
    func rate(for currencyCode: String) throws -> Decimal?
}

/// 折算共用口径（设计文档 §4、裁决 16：本位币锁定 CNY）
enum FxConversion {
    static let baseCurrencyCode = "CNY"

    /// 跨币种报销分摊校验的近似比较容差（设计文档 §5.5：具名常量，初始 1%，随真实数据校准）
    static let reimbursementToleranceRatio = Decimal(string: "0.01")!

    /// 外币最小货币单位金额按汇率快照折本位币分，四舍五入（与快照/分期同用 .plain 口径）
    static func toBaseMinorUnits(_ minorUnits: Int, rate: Decimal) -> Int {
        var raw = Decimal(minorUnits) * rate
        var rounded = Decimal()
        NSDecimalRound(&rounded, &raw, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }
}

/// 「流水快照即汇率字典」（设计文档 §4 折算口径②）：
/// 该币种全库最近一笔活跃流水的 fxRateToBase，随记账自动更新；
/// 无快照返回 nil（展示层按 1:1 折算并醒目提示）。同时用于记账页汇率预填。
struct FxRateProvider: ExchangeRateProviding {
    let context: ModelContext

    func rate(for currencyCode: String) throws -> Decimal? {
        guard currencyCode != FxConversion.baseCurrencyCode else { return 1 }
        var descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate {
                !$0.isSoftDeleted && $0.currencyCode == currencyCode && $0.fxRateToBase != nil
            },
            sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.fxRateToBase
    }
}
