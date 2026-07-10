import Foundation

/// 统计口径派生（设计文档 5.4）：投影层共用，勿在页面重算。
/// 退款冲减对应分类支出需 join StoredTransactionLink，M2 报销切片实现。
extension StoredTransaction {
    /// 统计收入（分）：income 且非报销到账计 amount（报销到账是费用冲减，计入会虚增收入）。
    var statsIncomeMinorUnits: Int {
        guard !isExcludedFromStats, kind == .income, settlementKind != .reimbursement else { return 0 }
        return amountMinorUnits
    }

    /// 统计支出（分）：expense 计 amount；fee 恒为流出一并计入（转账手续费/分期利息）。
    var statsExpenseMinorUnits: Int {
        guard !isExcludedFromStats else { return 0 }
        return (kind == .expense ? amountMinorUnits : 0) + feeMinorUnits
    }
}
