import Testing
@testable import zanzan

struct ModelEnumsTests {
    @Test func 多词rawValue与文档锁定一致() {
        // 单词 case 的 rawValue 不会漂移，只锁多词拼写（落库串终生不改）
        #expect(TransactionSourceKind.csvImport.rawValue == "csvImport")
        #expect(AmortizationKind.linearPrincipal.rawValue == "linearPrincipal")
        #expect(AmortizationKind.interestOnly.rawValue == "interestOnly")
        #expect(AmortizationKind.flatFee.rawValue == "flatFee")
        #expect(InstallmentPlanStatus.settledEarly.rawValue == "settledEarly")
    }

    @Test func 枚举取值数量与文档一致() {
        #expect(TransactionKind.allCases.count == 3)
        #expect(AccountKind.allCases.count == 6)
        #expect(TransactionSourceKind.allCases.count == 6)
        #expect(TransactionLinkKind.allCases.count == 2)
        #expect(ReimbursementStatus.allCases.count == 2)
        #expect(RecurrenceFrequency.allCases.count == 3)
        #expect(InstallmentPlanKind.allCases.count == 3)
        #expect(AmortizationKind.allCases.count == 5)
        #expect(InstallmentPlanStatus.allCases.count == 3)
        #expect(InstallmentPeriodStatus.allCases.count == 3)
    }

    @Test func 图标描述符Kind三种能力() {
        #expect(IconDescriptor.Kind(rawValue: "symbol") == .symbol)
        #expect(IconDescriptor.Kind(rawValue: "asset") == .asset)
        #expect(IconDescriptor.Kind(rawValue: "emoji") == .emoji)
        #expect(IconDescriptor.Kind(rawValue: "sticker") == nil)
    }
}
