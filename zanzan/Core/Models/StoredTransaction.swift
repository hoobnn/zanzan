import Foundation
import SwiftData

/// 流水主表（数据库设计文档 5.4）。kind 终生不可改写；
/// 复合索引匹配主查询 WHERE isSoftDeleted = 0 AND ledgerID = ? ORDER BY occurredAt DESC。
@Model
final class StoredTransaction {
    #Index<StoredTransaction>([\.uuid], [\.isSoftDeleted, \.ledgerID, \.occurredAt])

    /// 业务主键，表间弱引用一律指向它
    var uuid: UUID = UUID()
    // 核心
    /// expense / income / transfer；终生不可改写（修 iCost 报销陷阱）
    var kindRawValue: String = ""
    /// 金额（分，正数）
    var amountMinorUnits: Int = 0
    /// 业务发生时间（可回填补记）
    var occurredAt: Date = Date.now
    /// 备注
    var note: String = ""
    var ledgerID: UUID? = nil // 语义必填；CloudKit 兼容声明可空，命令层保证非空
    /// 收支账户；转账时为转出方
    var account: StoredAccount? = nil
    /// 转账转入方（非转账为 nil）
    var targetAccount: StoredAccount? = nil
    /// 收支分类（转账为 nil）
    var category: StoredCategory? = nil
    /// 标签（原生多对多，修钱迹逗号串之弊）
    var tags: [StoredTag]? = nil
    /// 附件（票据照片等）文件名，文件存沙盒 Attachments/，不入库（不随 CloudKit 同步）
    var attachmentFileNames: [String] = []
    /// 记账位置 POI 名（空 = 未记录）
    var locationName: String = ""
    /// 位置纬度（与 locationName 同记同空）
    var locationLatitude: Double? = nil
    /// 位置经度（与 locationName 同记同空）
    var locationLongitude: Double? = nil
    // 统计口径开关
    /// 该笔不计入预算已用额（iCost isNoCountBudget 对应物）
    var isExcludedFromBudget: Bool = false
    /// 该笔不计入收支统计（代付/走账场景）；余额永远照算
    var isExcludedFromStats: Bool = false
    // 多币种
    /// 记账币种（收支 = 账户币种；转账 = 转出方币种）
    var currencyCode: String = "CNY"
    /// 跨币种转账的转入方到账金额（转入账户币种计）；同币种为 nil
    var targetAmountMinorUnits: Int? = nil
    /// 记账时对本位币（CNY）汇率快照；非 CNY 流水命令层强制非空，本位币流水恒 nil
    var fxRateToBase: Decimal? = nil
    /// 转账手续费/分期利息（计入支出统计）
    var feeMinorUnits: Int = 0
    // 来源包
    /// 来源：manual / csvImport / recurring / voice / installment / adjustment
    var sourceKindRawValue: String = "manual"
    /// → StoredImportBatch / StoredRecurringRule / StoredInstallmentPlan 的 uuid
    var sourceID: UUID? = nil
    // 报销/退款
    /// "" / waiting / settled（仅垫付支出单持有）
    var reimbursementStatusRawValue: String = ""
    /// "" / reimbursement / refund（仅到账单持有，命令层与关联行同步维护的冗余身份标记）
    var settlementKindRawValue: String = ""
    // 通用
    /// 软删除标记，全库无硬删除
    var isSoftDeleted: Bool = false
    /// 创建时间
    var createdAt: Date = Date.now
    /// 最后修改时间（命令层维护）
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
