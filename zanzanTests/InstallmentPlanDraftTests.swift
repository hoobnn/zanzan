import Foundation
import Testing
@testable import zanzan

@MainActor
struct InstallmentPlanDraftTests {
    private let firstDueAt = Date(timeIntervalSince1970: 1_786_000_000)

    private func flatFeeDraft() -> InstallmentPlanDraft {
        var draft = InstallmentPlanDraft(firstDueAt: firstDueAt)
        draft.name = " iPhone 分期 "
        draft.kind = .purchase
        draft.accountID = UUID()
        draft.ledgerID = UUID()
        draft.principalMinorUnits = 999_900
        draft.totalPeriods = 24
        draft.amortizationKind = .flatFee
        draft.flatFeePerPeriodMinorUnits = 2_500
        return draft
    }

    @Test func 合法草稿通过并归一化() throws {
        let v = try flatFeeDraft().validated()
        #expect(v.name == "iPhone 分期") // trim 归一化
        #expect(v.principalMinorUnits == 999_900)
        #expect(v.totalPeriods == 24)
        #expect(v.totalChargeMinorUnits == 60_000) // 旧每期手续费入口归一化为息费总额
        #expect(v.annualRateBps == nil) // 固定手续费类分期年利率恒 nil（5.9）
        #expect(v.customPeriods.isEmpty)
    }

    @Test func 名称为空被拒() throws {
        var draft = flatFeeDraft()
        draft.name = "   "
        #expect(throws: InstallmentPlanDraftError.emptyName) { _ = try draft.validated() }
    }

    @Test func 缺账户或账本被拒() throws {
        var draft = flatFeeDraft()
        draft.accountID = nil
        #expect(throws: InstallmentPlanDraftError.missingAccount) { _ = try draft.validated() }
        draft = flatFeeDraft()
        draft.ledgerID = nil
        #expect(throws: InstallmentPlanDraftError.missingLedger) { _ = try draft.validated() }
    }

    @Test func 本金非正被拒() throws {
        var draft = flatFeeDraft()
        draft.principalMinorUnits = 0
        #expect(throws: InstallmentPlanDraftError.nonPositivePrincipal) { _ = try draft.validated() }
        draft.principalMinorUnits = -100
        #expect(throws: InstallmentPlanDraftError.nonPositivePrincipal) { _ = try draft.validated() }
    }

    @Test func 期数小于一被拒() throws {
        var draft = flatFeeDraft()
        draft.totalPeriods = 0
        #expect(throws: InstallmentPlanDraftError.invalidTotalPeriods) { _ = try draft.validated() }
    }

    @Test func 本金少于期数被拒() throws {
        // 每期本金至少 1 分（期供流水 amount 恒正的可执行性约束）
        var draft = flatFeeDraft()
        draft.principalMinorUnits = 23
        draft.totalPeriods = 24
        #expect(throws: InstallmentPlanDraftError.principalLessThanPeriods) { _ = try draft.validated() }
    }

    @Test func 计息方式缺年利率被拒() throws {
        for kind in [AmortizationKind.annuity, .linearPrincipal, .interestOnly] {
            var draft = flatFeeDraft()
            draft.amortizationKind = kind
            draft.annualRateBps = nil
            #expect(throws: InstallmentPlanDraftError.missingAnnualRate) { _ = try draft.validated() }
        }
    }

    @Test func 年利率为负被拒且为零可通过() throws {
        var draft = flatFeeDraft()
        draft.amortizationKind = .annuity
        draft.annualRateBps = -1
        #expect(throws: InstallmentPlanDraftError.negativeAnnualRate) { _ = try draft.validated() }
        draft.annualRateBps = 0 // 免息分期
        let v = try draft.validated()
        #expect(v.annualRateBps == 0)
    }

    @Test func 多期先息后本精确拒绝零利率_单期仍可免息() throws {
        var draft = flatFeeDraft()
        draft.amortizationKind = .interestOnly
        draft.annualRateBps = 0
        #expect(throws: InstallmentPlanDraftError.zeroRateMultiPeriodInterestOnly) {
            _ = try draft.validated()
        }

        draft.totalPeriods = 1
        let validated = try draft.validated()
        #expect(validated.annualRateBps == 0)
    }

    @Test func 自动结算保留字段当前必须为false() {
        var draft = flatFeeDraft()
        draft.isAutoSettle = true
        #expect(throws: InstallmentPlanDraftError.automaticSettlementUnsupported) {
            _ = try draft.validated()
        }
    }

    @Test func flatFee缺手续费或为负被拒() throws {
        var draft = flatFeeDraft()
        draft.flatFeePerPeriodMinorUnits = nil
        #expect(throws: InstallmentPlanDraftError.missingFlatFee) { _ = try draft.validated() }
        draft.flatFeePerPeriodMinorUnits = -1
        #expect(throws: InstallmentPlanDraftError.negativeFlatFee) { _ = try draft.validated() }
        draft.flatFeePerPeriodMinorUnits = 0 // 免手续费分期合法
        _ = try draft.validated()
    }

    @Test func 计息方式忽略无关字段() throws {
        // 归一化：annuity 不承载固定手续费（同 TransactionDraft 非转账 fee 归零先例）
        var draft = flatFeeDraft()
        draft.amortizationKind = .annuity
        draft.annualRateBps = 1_200
        draft.flatFeePerPeriodMinorUnits = 999
        let v = try draft.validated()
        #expect(v.totalChargeMinorUnits == nil)
        #expect(v.annualRateBps == 1_200)
    }

    @Test func 先息后本允许纯息期且保留利率() throws {
        var draft = flatFeeDraft()
        draft.amortizationKind = .interestOnly
        draft.annualRateBps = 1_200
        draft.principalMinorUnits = 1 // 先息后本不要求本金至少等于期数
        let v = try draft.validated()
        #expect(v.amortizationKind == .interestOnly)
        #expect(v.annualRateBps == 1_200)
        #expect(v.principalMinorUnits == 1)
    }

    @Test func custom行数不匹配被拒() throws {
        var draft = flatFeeDraft()
        draft.amortizationKind = .custom
        draft.totalPeriods = 3
        draft.principalMinorUnits = 10_000
        draft.customPeriods = [.init(principalMinorUnits: 10_000, interestMinorUnits: 0)]
        #expect(throws: InstallmentPlanDraftError.customPeriodCountMismatch) { _ = try draft.validated() }
    }

    @Test func custom本金合计不等被拒() throws {
        var draft = flatFeeDraft()
        draft.amortizationKind = .custom
        draft.totalPeriods = 2
        draft.principalMinorUnits = 10_000
        draft.customPeriods = [
            .init(principalMinorUnits: 5_000, interestMinorUnits: 0),
            .init(principalMinorUnits: 4_999, interestMinorUnits: 0),
        ]
        #expect(throws: InstallmentPlanDraftError.customPrincipalSumMismatch) { _ = try draft.validated() }
    }

    @Test func custom单期非法被拒() throws {
        var draft = flatFeeDraft()
        draft.amortizationKind = .custom
        draft.totalPeriods = 2
        draft.principalMinorUnits = 10_000
        draft.customPeriods = [
            .init(principalMinorUnits: 10_000, interestMinorUnits: 0),
            .init(principalMinorUnits: 0, interestMinorUnits: 0), // 零本金期不可执行
        ]
        #expect(throws: InstallmentPlanDraftError.invalidCustomPeriod) { _ = try draft.validated() }
        draft.customPeriods = [
            .init(principalMinorUnits: 5_000, interestMinorUnits: -1), // 负利息
            .init(principalMinorUnits: 5_000, interestMinorUnits: 0),
        ]
        #expect(throws: InstallmentPlanDraftError.invalidCustomPeriod) { _ = try draft.validated() }
    }

    @Test func custom合法草稿照录() throws {
        var draft = flatFeeDraft()
        draft.amortizationKind = .custom
        draft.totalPeriods = 2
        draft.principalMinorUnits = 10_000
        draft.customPeriods = [
            .init(principalMinorUnits: 6_000, interestMinorUnits: 30),
            .init(principalMinorUnits: 4_000, interestMinorUnits: 20),
        ]
        let v = try draft.validated()
        #expect(v.customPeriods == draft.customPeriods)
        #expect(v.totalChargeMinorUnits == nil)
        #expect(v.annualRateBps == nil)
    }

    @Test func 四个银行预设映射完整且规则不含费率金额() {
        #expect(InstallmentCalculationPreset.allCases == [
            .standard, .icbcPerPeriod, .icbcUpfront, .abc,
        ])

        #expect(InstallmentCalculationPreset.standard.rules == .init(
            chargeCollectionKind: .perPeriod,
            principalRoundingKind: .downToMinorUnit,
            principalRemainderKind: .lastPeriod,
            chargeRoundingKind: .downToMinorUnit,
            chargeRemainderKind: .lastPeriod
        ))
        #expect(InstallmentCalculationPreset.icbcPerPeriod.rules == .init(
            chargeCollectionKind: .perPeriod,
            principalRoundingKind: .downToMinorUnit,
            principalRemainderKind: .firstPeriod,
            chargeRoundingKind: .downToMinorUnit,
            chargeRemainderKind: .firstPeriod
        ))
        #expect(InstallmentCalculationPreset.icbcUpfront.rules == .init(
            chargeCollectionKind: .upfrontFirstPeriod,
            principalRoundingKind: .downToMinorUnit,
            principalRemainderKind: .firstPeriod,
            chargeRoundingKind: .downToMinorUnit,
            chargeRemainderKind: .firstPeriod
        ))
        #expect(InstallmentCalculationPreset.abc.rules == .init(
            chargeCollectionKind: .perPeriod,
            principalRoundingKind: .nearestMajorUnit,
            principalRemainderKind: .lastPeriod,
            chargeRoundingKind: .nearestMinorUnit,
            chargeRemainderKind: .lastPeriod
        ))

        let expectedLabels: Set<String> = [
            "chargeCollectionKind",
            "principalRoundingKind",
            "principalRemainderKind",
            "chargeRoundingKind",
            "chargeRemainderKind",
        ]
        for preset in InstallmentCalculationPreset.allCases {
            let labels = Set(Mirror(reflecting: preset.rules).children.compactMap(\.label))
            #expect(labels == expectedLabels)
            #expect(!labels.contains(where: { $0.localizedCaseInsensitiveContains("rate") }))
            #expect(!labels.contains(where: { $0.localizedCaseInsensitiveContains("amount") }))
        }
    }

    @Test func 银行预设限定产品范围并只读关联官网来源() {
        #expect(
            ZanzanLocalization.string(
                InstallmentCalculationPreset.icbcPerPeriod.title,
                language: .simplifiedChinese
            ) == "工行信用卡现金分期（分期收取）"
        )
        #expect(
            ZanzanLocalization.string(
                InstallmentCalculationPreset.icbcUpfront.title,
                language: .simplifiedChinese
            ) == "工行信用卡现金分期（首期一次收取）"
        )
        #expect(InstallmentCalculationPreset.standard.sourceURL == nil)
        #expect(
            InstallmentCalculationPreset.icbcPerPeriod.sourceURL?.absoluteString
                == "https://media.icbc.com.cn/agreement/1200289008933597184.html"
        )
        #expect(
            InstallmentCalculationPreset.icbcUpfront.sourceURL
                == InstallmentCalculationPreset.icbcPerPeriod.sourceURL
        )
        #expect(
            InstallmentCalculationPreset.abc.sourceURL?.absoluteString
                == "https://www.abchina.com/cn/CreditCard/AboutUs/Update/202510/W020251029598620797047.pdf"
        )
        for preset in InstallmentCalculationPreset.allCases {
            #expect(
                !ZanzanLocalization.string(
                    preset.productScopeNote,
                    language: .simplifiedChinese
                ).isEmpty
            )
        }
    }

    // MARK: - DraftLimits 边界

    @Test func 名称恰达上限通过() throws {
        var draft = flatFeeDraft()
        draft.name = String(repeating: "名", count: 100)
        #expect(try draft.validated().name.count == 100)
    }

    @Test func 名称超上限拒绝() {
        var draft = flatFeeDraft()
        draft.name = String(repeating: "名", count: 101)
        #expect(throws: InstallmentPlanDraftError.nameTooLong) { _ = try draft.validated() }
    }

    @Test func 备注恰达上限通过() throws {
        var draft = flatFeeDraft()
        draft.note = String(repeating: "备", count: 500)
        #expect(try draft.validated().note.count == 500)
    }

    @Test func 备注超上限拒绝() {
        var draft = flatFeeDraft()
        draft.note = String(repeating: "备", count: 501)
        #expect(throws: InstallmentPlanDraftError.noteTooLong) { _ = try draft.validated() }
    }

    @Test func 期数恰达上限通过() throws {
        var draft = flatFeeDraft()
        draft.totalPeriods = 600
        #expect(try draft.validated().totalPeriods == 600)
    }

    @Test func 期数超上限拒绝() {
        var draft = flatFeeDraft()
        draft.totalPeriods = 601
        #expect(throws: InstallmentPlanDraftError.tooManyPeriods) { _ = try draft.validated() }
    }

    @Test func 年利率恰达上限通过() throws {
        var draft = flatFeeDraft()
        draft.amortizationKind = .annuity
        draft.annualRateBps = 100_000
        #expect(try draft.validated().annualRateBps == 100_000)
    }

    @Test func 年利率超上限拒绝() {
        var draft = flatFeeDraft()
        draft.amortizationKind = .annuity
        draft.annualRateBps = 100_001
        #expect(throws: InstallmentPlanDraftError.annualRateTooHigh) { _ = try draft.validated() }
    }

    @Test func 首期还款日边界通过() throws {
        var draft = flatFeeDraft()
        draft.firstDueAt = Date(timeIntervalSince1970: 0)
        _ = try draft.validated()
    }

    @Test func 首期还款日越界拒绝() {
        for ts: TimeInterval in [-1, 4_102_444_800] {
            var draft = flatFeeDraft()
            draft.firstDueAt = Date(timeIntervalSince1970: ts)
            #expect(throws: InstallmentPlanDraftError.firstDueAtOutOfRange) { _ = try draft.validated() }
        }
    }
}
