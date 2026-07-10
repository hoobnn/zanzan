import Foundation
import Testing
@testable import zanzan

@MainActor
struct RecurringRuleDraftTests {
    private let ledgerID = UUID()
    private let accountID = UUID()
    private let targetAccountID = UUID()
    private let categoryID = UUID()

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 9) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// 默认：月频支出草稿，startAt = 2026-07-05 09:00
    private func makeDraft(
        frequency: RecurrenceFrequency = .monthly,
        kind: TransactionKind = .expense
    ) -> RecurringRuleDraft {
        var draft = RecurringRuleDraft(startAt: date(2026, 7, 5), templateLedgerID: ledgerID)
        draft.name = "房租"
        draft.frequency = frequency
        draft.amountString = "3500"
        draft.templateKind = kind
        draft.templateAccountID = accountID
        draft.templateCategoryID = categoryID
        return draft
    }

    // MARK: - 成功路径与归一化

    @Test func 月频草稿校验通过并归一化() throws {
        var draft = makeDraft()
        draft.name = "  房租  "
        draft.templateNote = " 每月房租 "
        let v = try draft.validated()
        #expect(v.name == "房租")
        #expect(v.frequency == .monthly)
        #expect(v.interval == 1)
        #expect(v.recurrenceDays == [5]) // 留空从 startAt（5 号）推导
        #expect(v.templateAmountMinorUnits == 350_000)
        #expect(v.templateLedgerID == ledgerID)
        #expect(v.templateAccountID == accountID)
        #expect(v.templateCategoryID == categoryID)
        #expect(v.templateTargetAccountID == nil)
        #expect(v.templateNote == "每月房租")
    }

    @Test func 显式触发日去重升序() throws {
        var draft = makeDraft()
        draft.recurrenceDays = [15, 5, 15, 31]
        let v = try draft.validated()
        #expect(v.recurrenceDays == [5, 15, 31])
    }

    @Test func 周频留空触发日从startAt推导() throws {
        let draft = makeDraft(frequency: .weekly)
        let expected = Calendar.current.component(.weekday, from: date(2026, 7, 5))
        let v = try draft.validated()
        #expect(v.recurrenceDays == [expected])
    }

    @Test func 日频触发日被防御性清空() throws {
        var draft = makeDraft(frequency: .daily)
        draft.recurrenceDays = [3, 5]
        let v = try draft.validated()
        #expect(v.recurrenceDays.isEmpty)
    }

    @Test func 转账草稿分类被防御性归nil() throws {
        var draft = makeDraft(kind: .transfer)
        draft.templateTargetAccountID = targetAccountID
        let v = try draft.validated()
        #expect(v.templateCategoryID == nil)
        #expect(v.templateTargetAccountID == targetAccountID)
    }

    @Test func 标签去重保持顺序() throws {
        let tagA = UUID()
        let tagB = UUID()
        var draft = makeDraft()
        draft.templateTagIDs = [tagA, tagB, tagA]
        let v = try draft.validated()
        #expect(v.templateTagIDs == [tagA, tagB])
    }

    // MARK: - 校验失败

    @Test func 空名称被拒() throws {
        var draft = makeDraft()
        draft.name = "   "
        #expect(throws: RecurringRuleDraftError.self) { try draft.validated() }
    }

    @Test func 间隔非正被拒() throws {
        var draft = makeDraft()
        draft.interval = 0
        #expect(throws: RecurringRuleDraftError.self) { try draft.validated() }
    }

    @Test(arguments: ["0", "-5", "abc", "1.234"])
    func 金额非法被拒(amount: String) throws {
        var draft = makeDraft()
        draft.amountString = amount
        #expect(throws: RecurringRuleDraftError.self) { try draft.validated() }
    }

    @Test func 周频触发日越界被拒() throws {
        var draft = makeDraft(frequency: .weekly)
        draft.recurrenceDays = [8]
        #expect(throws: RecurringRuleDraftError.self) { try draft.validated() }
    }

    @Test(arguments: [[0], [32]])
    func 月频触发日越界被拒(days: [Int]) throws {
        var draft = makeDraft()
        draft.recurrenceDays = days
        #expect(throws: RecurringRuleDraftError.self) { try draft.validated() }
    }

    @Test func 截止早于开始被拒() throws {
        var draft = makeDraft()
        draft.endAt = date(2026, 7, 4)
        #expect(throws: RecurringRuleDraftError.self) { try draft.validated() }
    }

    @Test func 缺账户被拒() throws {
        var draft = makeDraft()
        draft.templateAccountID = nil
        #expect(throws: RecurringRuleDraftError.self) { try draft.validated() }
    }

    @Test func 收支缺分类被拒() throws {
        var draft = makeDraft()
        draft.templateCategoryID = nil
        #expect(throws: RecurringRuleDraftError.self) { try draft.validated() }
    }

    @Test func 转账缺转入方被拒() throws {
        let draft = makeDraft(kind: .transfer)
        #expect(throws: RecurringRuleDraftError.self) { try draft.validated() }
    }

    @Test func 转账同账户被拒() throws {
        var draft = makeDraft(kind: .transfer)
        draft.templateTargetAccountID = accountID
        #expect(throws: RecurringRuleDraftError.self) { try draft.validated() }
    }
}
