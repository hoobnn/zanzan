import Foundation

/// 统计口径派生（设计文档 5.4）：投影层共用，勿在页面重算。
/// 退款冲减对应分类支出需 join TransactionLink，见 MonthlyStatsProvider。
extension Transaction {
    /// 统计收入（分）：income 且非报销/退款到账计 amount
    /// （报销到账是费用冲减、退款到账冲减支出，计入均会虚增收入）。
    var statsIncomeMinorUnits: Int {
        guard !isExcludedFromStats, kind == .income, settlementKind == nil else { return 0 }
        return amountMinorUnits
    }

    /// 统计支出（分）：expense 计 amount（垫付支出照常计入）；退款到账计 −amount（冲减支出）；
    /// fee 恒为流出一并计入（转账手续费/分期利息）。
    var statsExpenseMinorUnits: Int {
        guard !isExcludedFromStats else { return 0 }
        let base = switch (kind, settlementKind) {
        case (.expense, _): amountMinorUnits
        case (.income, .refund): -amountMinorUnits
        default: 0
        }
        return base + feeMinorUnits
    }
}
