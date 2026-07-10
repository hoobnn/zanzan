import Foundation

/// 分期/贷款计划表单草稿——入口校验 + 归一化（设计文档 5.9 命令层不变量的 Draft 侧）。
///
/// 可执行性硬约束：期供流水 amount = 该期本金且恒为正（5.4），故**每期本金至少 1 分**——
/// 由「本金 ≥ 期数」与 custom 逐期校验共同保证；除不尽尾差归末期由 Service 生成期表时执行。
///
/// interestOnly（先息后本）按 5.10 前 n−1 期本金为 0，与 5.4「amount 恒正」+
/// TransactionService 转账入口（amount > 0）冲突——零本金期无法生成合法期供流水，
/// 本切片在入口处阻断（fail fast），待流水层支持纯利息期后放开。
struct InstallmentPlanDraft {
    /// custom 方式的逐期录入行
    struct CustomPeriodInput: Equatable {
        var principalMinorUnits: Int
        var interestMinorUnits: Int
    }

    var name: String = ""
    var kind: InstallmentPlanKind = .purchase
    var accountID: UUID? = nil
    var ledgerID: UUID? = nil
    var principalMinorUnits: Int = 0
    var totalPeriods: Int = 0
    /// 年利率（基点）；annuity / linearPrincipal 必填（可为 0 = 免息），其余方式归一化为 nil
    var annualRateBps: Int? = nil
    var amortizationKind: AmortizationKind = .flatFee
    /// 首期还款日（业务时间由调用方注入，无默认值）
    var firstDueAt: Date
    var isAutoSettle: Bool = false
    var note: String = ""
    /// flatFee 方式的每期固定手续费（分）；仅 flatFee 必填
    var flatFeePerPeriodMinorUnits: Int? = nil
    /// custom 方式的逐期本息；行数必须等于 totalPeriods 且本金合计等于总本金
    var customPeriods: [CustomPeriodInput] = []

    struct Validated {
        let name: String
        let kind: InstallmentPlanKind
        let accountID: UUID
        let ledgerID: UUID
        let principalMinorUnits: Int
        let totalPeriods: Int
        let annualRateBps: Int?
        let amortizationKind: AmortizationKind
        let firstDueAt: Date
        let isAutoSettle: Bool
        let note: String
        /// 仅 flatFee 非 nil
        let flatFeePerPeriodMinorUnits: Int?
        /// 仅 custom 非空
        let customPeriods: [CustomPeriodInput]
    }

    func validated() throws -> Validated {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw InstallmentPlanDraftError.emptyName }
        guard let accountID else { throw InstallmentPlanDraftError.missingAccount }
        guard let ledgerID else { throw InstallmentPlanDraftError.missingLedger }
        guard principalMinorUnits > 0 else { throw InstallmentPlanDraftError.nonPositivePrincipal }
        guard totalPeriods >= 1 else { throw InstallmentPlanDraftError.invalidTotalPeriods }
        // 每期本金至少 1 分（期供流水 amount 恒正的可执行性约束）
        guard principalMinorUnits >= totalPeriods else { throw InstallmentPlanDraftError.principalLessThanPeriods }

        // 利息口径按方式归一化：无关字段防御性清空（同 TransactionDraft 非转账 fee 归零的先例）
        var rate: Int? = nil
        var flatFee: Int? = nil
        var custom: [CustomPeriodInput] = []
        switch amortizationKind {
        case .annuity, .linearPrincipal:
            guard let annualRateBps else { throw InstallmentPlanDraftError.missingAnnualRate }
            guard annualRateBps >= 0 else { throw InstallmentPlanDraftError.negativeAnnualRate }
            rate = annualRateBps
        case .interestOnly:
            // 见类型注释：零本金期与 amount 恒正冲突，暂不支持
            throw InstallmentPlanDraftError.interestOnlyUnsupported
        case .flatFee:
            guard let flatFeePerPeriodMinorUnits else { throw InstallmentPlanDraftError.missingFlatFee }
            guard flatFeePerPeriodMinorUnits >= 0 else { throw InstallmentPlanDraftError.negativeFlatFee }
            flatFee = flatFeePerPeriodMinorUnits
        case .custom:
            guard customPeriods.count == totalPeriods else {
                throw InstallmentPlanDraftError.customPeriodCountMismatch
            }
            guard customPeriods.allSatisfy({ $0.principalMinorUnits >= 1 && $0.interestMinorUnits >= 0 }) else {
                throw InstallmentPlanDraftError.invalidCustomPeriod
            }
            let principalSum = customPeriods.reduce(0) { $0 + $1.principalMinorUnits }
            guard principalSum == principalMinorUnits else {
                throw InstallmentPlanDraftError.customPrincipalSumMismatch
            }
            custom = customPeriods
        }

        return Validated(
            name: name,
            kind: kind,
            accountID: accountID,
            ledgerID: ledgerID,
            principalMinorUnits: principalMinorUnits,
            totalPeriods: totalPeriods,
            annualRateBps: rate,
            amortizationKind: amortizationKind,
            firstDueAt: firstDueAt,
            isAutoSettle: isAutoSettle,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            flatFeePerPeriodMinorUnits: flatFee,
            customPeriods: custom
        )
    }
}

enum InstallmentPlanDraftError: LocalizedError, Equatable {
    case emptyName
    case missingAccount
    case missingLedger
    case nonPositivePrincipal
    case invalidTotalPeriods
    case principalLessThanPeriods
    case missingAnnualRate
    case negativeAnnualRate
    case interestOnlyUnsupported
    case missingFlatFee
    case negativeFlatFee
    case customPeriodCountMismatch
    case invalidCustomPeriod
    case customPrincipalSumMismatch

    var errorDescription: String? {
        switch self {
        case .emptyName: String(localized: "计划名称不能为空")
        case .missingAccount: String(localized: "请选择债务账户")
        case .missingLedger: String(localized: "请选择账本")
        case .nonPositivePrincipal: String(localized: "本金总额必须大于零")
        case .invalidTotalPeriods: String(localized: "总期数至少为 1 期")
        case .principalLessThanPeriods: String(localized: "本金总额不能少于期数（每期本金至少 1 分）")
        case .missingAnnualRate: String(localized: "该还款方式需要填写年利率")
        case .negativeAnnualRate: String(localized: "年利率不能为负")
        case .interestOnlyUnsupported: String(localized: "先息后本暂不支持")
        case .missingFlatFee: String(localized: "固定手续费方式需要填写每期手续费")
        case .negativeFlatFee: String(localized: "每期手续费不能为负")
        case .customPeriodCountMismatch: String(localized: "自定义期数行数须等于总期数")
        case .invalidCustomPeriod: String(localized: "自定义期数每期本金至少 1 分、利息不能为负")
        case .customPrincipalSumMismatch: String(localized: "自定义期数本金合计须等于本金总额")
        }
    }
}
