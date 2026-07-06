import Foundation
import SwiftData

/// 流水主表（数据库设计文档 5.4）。kind 终生不可改写；
/// 复合索引匹配主查询 WHERE isSoftDeleted = 0 AND ledgerID = ? ORDER BY occurredAt DESC。
@Model
final class StoredTransaction {
    #Index<StoredTransaction>([\.uuid], [\.isSoftDeleted, \.ledgerID, \.occurredAt])

    var uuid: UUID = UUID()
    // 核心
    var kindRawValue: String = ""
    var amountMinorUnits: Int = 0
    var occurredAt: Date = Date.now
    var note: String = ""
    var ledgerID: UUID? = nil // 语义必填；CloudKit 兼容声明可空，命令层保证非空
    var account: StoredAccount? = nil
    var targetAccount: StoredAccount? = nil
    var category: StoredCategory? = nil
    var tags: [StoredTag]? = nil
    var attachmentFileNames: [String] = []
    var locationName: String = ""
    var locationLatitude: Double? = nil
    var locationLongitude: Double? = nil
    // 统计口径开关
    var isExcludedFromBudget: Bool = false
    var isExcludedFromStats: Bool = false
    // 多币种
    var currencyCode: String = "CNY"
    var targetAmountMinorUnits: Int? = nil
    var fxRateToBase: Decimal? = nil
    var feeMinorUnits: Int = 0
    // 来源包
    var sourceKindRawValue: String = "manual"
    var sourceID: UUID? = nil
    // 报销/退款
    var reimbursementStatusRawValue: String = ""
    var settlementKindRawValue: String = ""
    // 通用
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    /// 语义类枚举：未知值返回 nil，原串保留、禁回写兜底（设计文档 §4 前向兼容）
    var kind: TransactionKind? { TransactionKind(rawValue: kindRawValue) }
    var sourceKind: TransactionSourceKind? { TransactionSourceKind(rawValue: sourceKindRawValue) }
    /// 空串 = 非报销单，与未知值同为 nil；区分逻辑属命令/投影层
    var reimbursementStatus: ReimbursementStatus? { ReimbursementStatus(rawValue: reimbursementStatusRawValue) }
    /// 空串 = 非到账单
    var settlementKind: TransactionLinkKind? { TransactionLinkKind(rawValue: settlementKindRawValue) }

    /// 收支符号金额：支出负、收入正、转账 0；语义未知按 0（读路径负责剔除与提示）
    var signedMinorUnits: Int {
        switch kind {
        case .expense: -amountMinorUnits
        case .income: amountMinorUnits
        case .transfer, nil: 0
        }
    }

    /// 对指定账户的余额影响（分）。fee 恒为流出：
    /// 转出方 delta = −(amount + fee)，转入方 = +(targetAmount ?? amount)（设计文档 5.4）。
    /// 语义未知的流水不影响余额（读路径按「未知」处理）。
    func balanceDeltaMinorUnits(for accountUUID: UUID) -> Int {
        guard let kind else { return 0 }
        let isSource = account?.uuid == accountUUID
        let isTarget = targetAccount?.uuid == accountUUID
        switch kind {
        case .expense:
            return isSource ? -(amountMinorUnits + feeMinorUnits) : 0
        case .income:
            return isSource ? amountMinorUnits - feeMinorUnits : 0
        case .transfer:
            var delta = 0
            if isSource { delta -= amountMinorUnits + feeMinorUnits }
            if isTarget { delta += targetAmountMinorUnits ?? amountMinorUnits }
            return delta
        }
    }

    init(kind: TransactionKind, amountMinorUnits: Int, occurredAt: Date, ledgerID: UUID) {
        self.kindRawValue = kind.rawValue
        self.amountMinorUnits = amountMinorUnits
        self.occurredAt = occurredAt
        self.ledgerID = ledgerID
    }
}
