import Foundation

/// 统计口径派生（设计文档 5.4 / §4 折算口径①）：投影层共用，勿在页面重算。
/// 所有统计金额一律折本位币（CNY）分：外币流水按**自身** `fxRateToBase` 快照折（历史口径永固）。
/// 退款冲减对应分类支出需 join TransactionLink，见 MonthlyStatsProvider。
/// @Model 扩展成员默认 nonisolated，显式标 @MainActor 以引用同隔离的 FxConversion（现有边界）。
@MainActor
extension Transaction {
    /// 口径①折算：本笔币种下的金额折本位币分。CNY 恒等；外币按自身快照折。
    /// 外币而 fxRateToBase 为 nil 属历史坏数据（命令层本应强制非空），
    /// 按 1:1 兜底不回写——§4「无快照按 1:1 并提示」口径的引申。
    func statsBaseMinorUnits(_ minorUnits: Int) -> Int {
        guard currencyCode != FxConversion.baseCurrencyCode, let rate = fxRateToBase else {
            return minorUnits
        }
        return FxConversion.toBaseMinorUnits(minorUnits, rate: rate)
    }

    /// 统计收入（本位币分）：income 且非报销/退款到账计 amount
    /// （报销到账是费用冲减、退款到账冲减支出，计入均会虚增收入）。
    var statsIncomeMinorUnits: Int {
        guard !isExcludedFromStats, kind == .income, settlementKind == nil else { return 0 }
        return statsBaseMinorUnits(amountMinorUnits)
    }

    /// 统计口径手续费（本位币分）：与收支同按自身快照折算，isExcludedFromStats 归零。
    /// 供「利息手续费」单列与预算分类口径扣减（statsExpense − statsFee 恰为折算后 amount，无舍入错位）。
    var statsFeeMinorUnits: Int {
        isExcludedFromStats ? 0 : statsBaseMinorUnits(feeMinorUnits)
    }

    /// 统计支出（本位币分）：expense 计 amount（垫付支出照常计入）；退款到账计 −amount（冲减支出）；
    /// fee 恒为流出一并计入（转账手续费/分期利息）。amount 与 fee 分别折算再相加，保证扣减口径自洽。
    var statsExpenseMinorUnits: Int {
        guard !isExcludedFromStats else { return 0 }
        let base = switch (kind, settlementKind) {
        case (.expense, _): statsBaseMinorUnits(amountMinorUnits)
        case (.income, .refund): -statsBaseMinorUnits(amountMinorUnits)
        default: 0
        }
        return base + statsBaseMinorUnits(feeMinorUnits)
    }
}
