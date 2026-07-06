import Foundation
import SwiftData

/// 资产/账户（数据库设计文档 5.2）。当前余额 = 期初 + 流水派生，不落库。
@Model
final class StoredAccount {
    #Index<StoredAccount>([\.uuid])

    /// 业务主键，表间弱引用一律指向它
    var uuid: UUID = UUID()
    /// 账户名
    var name: String = ""
    /// 副标题（银行/渠道名）
    var subtitle: String = ""
    /// 账户大类（见 AccountKind）
    var kindRawValue: String = ""
    /// 图标四件套：图标类型
    var iconKindRawValue: String = ""
    /// 图标四件套：主素材
    var iconPrimary: String = ""
    /// 图标四件套：副素材
    var iconSecondary: String = ""
    /// 图标四件套：备用序号
    var iconIndex: Int = 0
    /// 币种
    var currencyCode: String = "CNY"
    /// 期初余额；当前余额 = 期初 + 流水派生，不落库
    var initialBalanceMinorUnits: Int = 0
    /// 信用额度（仅 credit 类）：独立卡 = 自身额度；池成员 = 可选单卡子限额（nil = 仅受池约束）
    var creditLimitMinorUnits: Int? = nil
    /// → StoredCreditPool.uuid；nil = 独立额度；仅 credit 类可设（命令层校验）
    var creditPoolID: UUID? = nil
    /// 账单日（1–28）
    var statementDay: Int? = nil
    /// 还款日（1–28）
    var paymentDueDay: Int? = nil
    /// 备注
    var note: String = ""
    /// 是否计入净资产
    var isIncludedInNetWorth: Bool = true
    /// 记账时是否可选（活跃但不参与记账的精细控制，如公积金）
    var isSelectableForRecord: Bool = true
    /// 归档（停用：不可选 + 列表折叠；余额与统计照常，isIncludedInNetWorth 独立生效）
    var isArchived: Bool = false
    /// 组内排序
    var sortOrder: Int = 0
    /// 软删除标记，全库无硬删除
    var isSoftDeleted: Bool = false
    /// 创建时间
    var createdAt: Date = Date.now
    /// 最后修改时间（命令层维护）
    var updatedAt: Date = Date.now

    /// 收支流水 + 转账转出方（inverse of StoredTransaction.account）
    @Relationship(deleteRule: .nullify, inverse: \StoredTransaction.account)
    var transactions: [StoredTransaction]? = nil

    /// 转账转入方反查（inverse of StoredTransaction.targetAccount）
    @Relationship(deleteRule: .nullify, inverse: \StoredTransaction.targetAccount)
    var incomingTransfers: [StoredTransaction]? = nil

    /// 语义类枚举：未知值返回 nil，禁回写兜底（设计文档 §4 前向兼容）
    var kind: AccountKind? { AccountKind(rawValue: kindRawValue) }

    init(name: String, kind: AccountKind) {
        self.name = name
        self.kindRawValue = kind.rawValue
    }
}
