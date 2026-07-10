import Foundation
import Testing
@testable import zanzan

@MainActor
struct BudgetDraftTests {
    private let ledgerID = UUID()

    @Test func 模板行草稿校验通过() throws {
        var draft = BudgetDraft(ledgerID: ledgerID)
        draft.amountMinorUnits = 100_000
        let v = try draft.validated()
        #expect(v.ledgerID == ledgerID)
        #expect(v.categoryID == nil)
        #expect(v.periodYear == nil)
        #expect(v.periodMonth == nil)
        #expect(v.amountMinorUnits == 100_000)
    }

    @Test func 月度行草稿校验通过() throws {
        var draft = BudgetDraft(ledgerID: ledgerID)
        draft.categoryID = UUID()
        draft.periodYear = 2026
        draft.periodMonth = 7
        draft.amountMinorUnits = 50_000
        let v = try draft.validated()
        #expect(v.periodYear == 2026)
        #expect(v.periodMonth == 7)
    }

    @Test func 金额为零被拒() {
        var draft = BudgetDraft(ledgerID: ledgerID)
        draft.amountMinorUnits = 0
        #expect(throws: BudgetDraftError.self) { try draft.validated() }
    }

    @Test func 金额为负被拒() {
        var draft = BudgetDraft(ledgerID: ledgerID)
        draft.amountMinorUnits = -100
        #expect(throws: BudgetDraftError.self) { try draft.validated() }
    }

    @Test func 只填年不填月被拒() {
        var draft = BudgetDraft(ledgerID: ledgerID)
        draft.amountMinorUnits = 100
        draft.periodYear = 2026
        #expect(throws: BudgetDraftError.self) { try draft.validated() }
    }

    @Test func 只填月不填年被拒() {
        var draft = BudgetDraft(ledgerID: ledgerID)
        draft.amountMinorUnits = 100
        draft.periodMonth = 7
        #expect(throws: BudgetDraftError.self) { try draft.validated() }
    }

    @Test(arguments: [0, 13]) func 月份越界被拒(month: Int) {
        var draft = BudgetDraft(ledgerID: ledgerID)
        draft.amountMinorUnits = 100
        draft.periodYear = 2026
        draft.periodMonth = month
        #expect(throws: BudgetDraftError.self) { try draft.validated() }
    }

    @Test(arguments: [2000, 2100]) func 年份边界通过(year: Int) throws {
        var draft = BudgetDraft(ledgerID: ledgerID)
        draft.amountMinorUnits = 100
        draft.periodYear = year
        draft.periodMonth = 1
        #expect(try draft.validated().periodYear == year)
    }

    @Test(arguments: [1999, 2101]) func 年份越界被拒(year: Int) {
        var draft = BudgetDraft(ledgerID: ledgerID)
        draft.amountMinorUnits = 100
        draft.periodYear = year
        draft.periodMonth = 1
        #expect(throws: BudgetDraftError.invalidYear) { try draft.validated() }
    }
}
