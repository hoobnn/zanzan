import Foundation

/// 分期/贷款计划表单草稿——入口校验 + 归一化（设计文档 5.9 命令层不变量的 Draft 侧）。
///
/// 普通方式每期本金至少 1 个最小货币单位；先息后本允许前期本金为 0，
/// 但对应期必须有正息费，且仅能经分期服务生成。
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
    /// 固定息费总额（新入口）；与旧的每期固定手续费二选一，新值优先。
    var totalChargeMinorUnits: Int? = nil
    var chargeCollectionKind: ChargeCollectionKind = .perPeriod
    var principalRoundingKind: InstallmentRoundingKind = .downToMinorUnit
    var principalRemainderKind: InstallmentRemainderKind = .lastPeriod
    var chargeRoundingKind: InstallmentRoundingKind = .downToMinorUnit
    var chargeRemainderKind: InstallmentRemainderKind = .lastPeriod
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
        let totalChargeMinorUnits: Int?
        let chargeCollectionKind: ChargeCollectionKind
        let principalRoundingKind: InstallmentRoundingKind
        let principalRemainderKind: InstallmentRemainderKind
        let chargeRoundingKind: InstallmentRoundingKind
        let chargeRemainderKind: InstallmentRemainderKind
        /// 仅 custom 非空
        let customPeriods: [CustomPeriodInput]
    }

    func validated() throws -> Validated {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw InstallmentPlanDraftError.emptyName }
        guard name.count <= DraftLimits.maxNameLength else { throw InstallmentPlanDraftError.nameTooLong }
        guard let accountID else { throw InstallmentPlanDraftError.missingAccount }
        guard let ledgerID else { throw InstallmentPlanDraftError.missingLedger }
        guard principalMinorUnits > 0 else { throw InstallmentPlanDraftError.nonPositivePrincipal }
        guard principalMinorUnits <= MoneyAmount.maxAbsoluteMinorUnits else {
            throw InstallmentPlanDraftError.amountTooHigh
        }
        guard totalPeriods >= 1 else { throw InstallmentPlanDraftError.invalidTotalPeriods }
        guard totalPeriods <= DraftLimits.maxInstallmentPeriods else {
            throw InstallmentPlanDraftError.tooManyPeriods
        }
        guard DraftLimits.occurredAtRange.contains(firstDueAt) else {
            throw InstallmentPlanDraftError.firstDueAtOutOfRange
        }
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note.count <= DraftLimits.maxNoteLength else { throw InstallmentPlanDraftError.noteTooLong }
        guard !isAutoSettle else {
            throw InstallmentPlanDraftError.automaticSettlementUnsupported
        }
        // 利息口径按方式归一化：无关字段防御性清空（同 TransactionDraft 非转账 fee 归零的先例）
        var rate: Int? = nil
        var totalCharge: Int? = nil
        var custom: [CustomPeriodInput] = []
        switch amortizationKind {
        case .annuity, .linearPrincipal, .interestOnly:
            guard let annualRateBps else { throw InstallmentPlanDraftError.missingAnnualRate }
            guard annualRateBps >= 0 else { throw InstallmentPlanDraftError.negativeAnnualRate }
            guard annualRateBps <= DraftLimits.maxAnnualRateBps else {
                throw InstallmentPlanDraftError.annualRateTooHigh
            }
            if amortizationKind == .interestOnly,
               totalPeriods > 1,
               annualRateBps == 0 {
                throw InstallmentPlanDraftError.zeroRateMultiPeriodInterestOnly
            }
            rate = annualRateBps
        case .flatFee:
            if let totalChargeMinorUnits {
                guard totalChargeMinorUnits >= 0 else { throw InstallmentPlanDraftError.negativeFlatFee }
                totalCharge = totalChargeMinorUnits
            } else {
                guard let flatFeePerPeriodMinorUnits else {
                    throw InstallmentPlanDraftError.missingFlatFee
                }
                guard flatFeePerPeriodMinorUnits >= 0 else {
                    throw InstallmentPlanDraftError.negativeFlatFee
                }
                let (legacyTotal, overflow) = flatFeePerPeriodMinorUnits
                    .multipliedReportingOverflow(by: totalPeriods)
                guard !overflow else { throw InstallmentPlanDraftError.amountTooHigh }
                totalCharge = legacyTotal
            }
            guard totalCharge! <= MoneyAmount.maxAbsoluteMinorUnits else {
                throw InstallmentPlanDraftError.amountTooHigh
            }
        case .custom:
            guard customPeriods.count == totalPeriods else {
                throw InstallmentPlanDraftError.customPeriodCountMismatch
            }
            guard customPeriods.allSatisfy({
                $0.principalMinorUnits >= 1
                    && $0.principalMinorUnits <= MoneyAmount.maxAbsoluteMinorUnits
                    && $0.interestMinorUnits >= 0
                    && $0.interestMinorUnits <= MoneyAmount.maxAbsoluteMinorUnits
            }) else {
                throw InstallmentPlanDraftError.invalidCustomPeriod
            }
            let principalSum = try checkedSum(customPeriods.map(\.principalMinorUnits))
            guard principalSum == principalMinorUnits else {
                throw InstallmentPlanDraftError.customPrincipalSumMismatch
            }
            custom = customPeriods
        }
        if amortizationKind != .interestOnly {
            guard principalMinorUnits >= totalPeriods else {
                throw InstallmentPlanDraftError.principalLessThanPeriods
            }
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
            note: note,
            totalChargeMinorUnits: totalCharge,
            chargeCollectionKind: amortizationKind == .flatFee ? chargeCollectionKind : .perPeriod,
            principalRoundingKind: amortizationKind == .flatFee ? principalRoundingKind : .downToMinorUnit,
            principalRemainderKind: amortizationKind == .flatFee ? principalRemainderKind : .lastPeriod,
            chargeRoundingKind: amortizationKind == .flatFee ? chargeRoundingKind : .downToMinorUnit,
            chargeRemainderKind: amortizationKind == .flatFee ? chargeRemainderKind : .lastPeriod,
            customPeriods: custom
        )
    }

    private func checkedSum(_ values: [Int]) throws -> Int {
        try values.reduce(0) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(value)
            guard !overflow else { throw InstallmentPlanDraftError.amountTooHigh }
            return sum
        }
    }
}

enum InstallmentPlanDraftError: LocalizedError, Equatable {
    case emptyName
    case nameTooLong
    case noteTooLong
    case missingAccount
    case missingLedger
    case nonPositivePrincipal
    case invalidTotalPeriods
    case tooManyPeriods
    case firstDueAtOutOfRange
    case principalLessThanPeriods
    case missingAnnualRate
    case negativeAnnualRate
    case annualRateTooHigh
    case zeroRateMultiPeriodInterestOnly
    case automaticSettlementUnsupported
    case amountTooHigh
    case missingFlatFee
    case negativeFlatFee
    case customPeriodCountMismatch
    case invalidCustomPeriod
    case customPrincipalSumMismatch

    var errorDescription: String? {
        switch self {
        case .emptyName: ZanzanLocalization.string( "计划名称不能为空")
        case .nameTooLong: ZanzanLocalization.string( "计划名称不能超过 \(DraftLimits.maxNameLength) 字")
        case .noteTooLong: ZanzanLocalization.string( "备注不能超过 \(DraftLimits.maxNoteLength) 字")
        case .missingAccount: ZanzanLocalization.string( "请选择债务账户")
        case .missingLedger: ZanzanLocalization.string( "请选择账本")
        case .nonPositivePrincipal: ZanzanLocalization.string( "本金总额必须大于零")
        case .invalidTotalPeriods: ZanzanLocalization.string( "总期数至少为 1 期")
        case .tooManyPeriods: ZanzanLocalization.string( "总期数不能超过 \(DraftLimits.maxInstallmentPeriods) 期")
        case .firstDueAtOutOfRange: ZanzanLocalization.string( "首期还款日超出可记账范围")
        case .principalLessThanPeriods: ZanzanLocalization.string( "本金总额不能少于期数（每期本金至少 1 分）")
        case .missingAnnualRate: ZanzanLocalization.string( "该还款方式需要填写年利率")
        case .negativeAnnualRate: ZanzanLocalization.string( "年利率不能为负")
        case .annualRateTooHigh: ZanzanLocalization.string( "年利率超出可接受上限")
        case .zeroRateMultiPeriodInterestOnly: ZanzanLocalization.string( "多期先息后本的年利率必须大于 0")
        case .automaticSettlementUnsupported: ZanzanLocalization.string( "当前版本尚不支持自动结算，请关闭后重试")
        case .amountTooHigh: ZanzanLocalization.string( "金额超出可支持范围")
        case .missingFlatFee: ZanzanLocalization.string( "固定手续费方式需要填写每期手续费")
        case .negativeFlatFee: ZanzanLocalization.string( "每期手续费不能为负")
        case .customPeriodCountMismatch: ZanzanLocalization.string( "自定义期数行数须等于总期数")
        case .invalidCustomPeriod: ZanzanLocalization.string( "自定义期数每期本金至少 1 分、利息不能为负")
        case .customPrincipalSumMismatch: ZanzanLocalization.string( "自定义期数本金合计须等于本金总额")
        }
    }
}

/// 银行预设只填充计算规则，不保存银行名称，也不提供费率或息费金额。
enum InstallmentCalculationPreset: String, CaseIterable, Identifiable {
    case standard
    case icbcPerPeriod
    case icbcUpfront
    case abc

    struct Rules: Equatable {
        let chargeCollectionKind: ChargeCollectionKind
        let principalRoundingKind: InstallmentRoundingKind
        let principalRemainderKind: InstallmentRemainderKind
        let chargeRoundingKind: InstallmentRoundingKind
        let chargeRemainderKind: InstallmentRemainderKind
    }

    var id: Self { self }

    var title: String.LocalizationValue {
        switch self {
        case .standard: "通用兼容"
        case .icbcPerPeriod: "工行信用卡现金分期（分期收取）"
        case .icbcUpfront: "工行信用卡现金分期（首期一次收取）"
        case .abc: "农行卡户分期"
        }
    }

    /// 只读产品范围说明；仅用于表单辅助，不进入 InstallmentPlan。
    var productScopeNote: String.LocalizationValue {
        switch self {
        case .standard:
            "适用范围：通用兼容模板，不对应任何银行产品。"
        case .icbcPerPeriod, .icbcUpfront:
            "适用范围：工行信用卡现金分期；收取方式以办理页面或合同为准。"
        case .abc:
            "适用范围：农行信用卡卡户分期（账单、消费、总账分期）。"
        }
    }

    /// 官网一手规则来源；与产品范围同为只读表单元数据，不持久化。
    var sourceURL: URL? {
        switch self {
        case .standard:
            nil
        case .icbcPerPeriod, .icbcUpfront:
            URL(string: "https://media.icbc.com.cn/agreement/1200289008933597184.html")
        case .abc:
            URL(
                string: "https://www.abchina.com/cn/CreditCard/AboutUs/Update/202510/"
                    + "W020251029598620797047.pdf"
            )
        }
    }

    var rules: Rules {
        switch self {
        case .standard:
            Rules(
                chargeCollectionKind: .perPeriod,
                principalRoundingKind: .downToMinorUnit,
                principalRemainderKind: .lastPeriod,
                chargeRoundingKind: .downToMinorUnit,
                chargeRemainderKind: .lastPeriod
            )
        case .icbcPerPeriod:
            Rules(
                chargeCollectionKind: .perPeriod,
                principalRoundingKind: .downToMinorUnit,
                principalRemainderKind: .firstPeriod,
                chargeRoundingKind: .downToMinorUnit,
                chargeRemainderKind: .firstPeriod
            )
        case .icbcUpfront:
            Rules(
                chargeCollectionKind: .upfrontFirstPeriod,
                principalRoundingKind: .downToMinorUnit,
                principalRemainderKind: .firstPeriod,
                chargeRoundingKind: .downToMinorUnit,
                chargeRemainderKind: .firstPeriod
            )
        case .abc:
            Rules(
                chargeCollectionKind: .perPeriod,
                principalRoundingKind: .nearestMajorUnit,
                principalRemainderKind: .lastPeriod,
                chargeRoundingKind: .nearestMinorUnit,
                chargeRemainderKind: .lastPeriod
            )
        }
    }
}
