import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct CreditCardStatementProviderTests {
    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func makeCreditCard(context: ModelContext, statementDay: Int?, limit: Int? = nil) -> Account {
        let card = Account(name: "信用卡", kind: .credit)
        card.statementDay = statementDay
        card.creditLimitMinorUnits = limit
        context.insert(card)
        return card
    }

    // MARK: - 周期切分

    @Test func 账单日中旬_参考日在账单日后_周期跨到下月() throws {
        let (start, end) = try CreditCardStatementProvider.statementPeriod(
            containing: date(2026, 7, 20), statementDay: 15, calendar: calendar
        )
        // 本期 = 7/16 ~ 8/15（账单日当天计入本期）
        #expect(calendar.dateComponents([.month, .day], from: start) == DateComponents(month: 7, day: 16))
        #expect(calendar.dateComponents([.month, .day], from: end) == DateComponents(month: 8, day: 16))
    }

    @Test func 参考日恰为账单日_当天是周期末() throws {
        let (start, end) = try CreditCardStatementProvider.statementPeriod(
            containing: date(2026, 7, 15), statementDay: 15, calendar: calendar
        )
        #expect(calendar.dateComponents([.month, .day], from: start) == DateComponents(month: 6, day: 16))
        #expect(calendar.dateComponents([.month, .day], from: end) == DateComponents(month: 7, day: 16))
    }

    @Test func 账单日31遇2月_收缩到月末() throws {
        // 2026 年非闰年，2 月 28 天
        let (start, end) = try CreditCardStatementProvider.statementPeriod(
            containing: date(2026, 2, 10), statementDay: 31, calendar: calendar
        )
        // 本期 = 2/1 ~ 2/28（上一账单日 1/31，本期账单日收缩为 2/28）
        #expect(calendar.dateComponents([.month, .day], from: start) == DateComponents(month: 2, day: 1))
        #expect(calendar.dateComponents([.month, .day], from: end) == DateComponents(month: 3, day: 1))
    }

    @Test func 账单日31的3月周期_起点在2月末次日() throws {
        let (start, end) = try CreditCardStatementProvider.statementPeriod(
            containing: date(2026, 3, 5), statementDay: 31, calendar: calendar
        )
        // 本期 = 3/1 ~ 3/31（上一账单日 2/28）
        #expect(calendar.dateComponents([.month, .day], from: start) == DateComponents(month: 3, day: 1))
        #expect(calendar.dateComponents([.month, .day], from: end) == DateComponents(month: 4, day: 1))
    }

    @Test func 十二月周期跨年() throws {
        let (start, end) = try CreditCardStatementProvider.statementPeriod(
            containing: date(2026, 12, 20), statementDay: 15, calendar: calendar
        )
        #expect(calendar.dateComponents([.year, .month, .day], from: start)
            == DateComponents(year: 2026, month: 12, day: 16))
        #expect(calendar.dateComponents([.year, .month, .day], from: end)
            == DateComponents(year: 2027, month: 1, day: 16))
    }

    @Test func 非法账单日抛错() throws {
        #expect(throws: CreditCardStatementProviderError.self) {
            try CreditCardStatementProvider.statementPeriod(
                containing: date(2026, 7, 1), statementDay: 0, calendar: calendar
            )
        }
    }

    // MARK: - 账单金额

    @Test func 本期账单金额只计周期内流水_还款冲抵() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let ledgerID = UUID()
        let card = makeCreditCard(context: context, statementDay: 15)
        let cash = Account(name: "现金", kind: .fund)
        context.insert(cash)

        let inPeriod = Transaction(kind: .expense, amountMinorUnits: 30_000, occurredAt: date(2026, 7, 20), ledgerID: ledgerID)
        inPeriod.account = card
        let withFee = Transaction(kind: .expense, amountMinorUnits: 10_000, occurredAt: date(2026, 8, 1), ledgerID: ledgerID)
        withFee.account = card
        withFee.feeMinorUnits = 500
        let outOfPeriod = Transaction(kind: .expense, amountMinorUnits: 99_999, occurredAt: date(2026, 7, 10), ledgerID: ledgerID)
        outOfPeriod.account = card
        let repayment = Transaction(kind: .transfer, amountMinorUnits: 5_000, occurredAt: date(2026, 8, 2), ledgerID: ledgerID)
        repayment.account = cash
        repayment.targetAccount = card
        let deleted = Transaction(kind: .expense, amountMinorUnits: 7_777, occurredAt: date(2026, 8, 3), ledgerID: ledgerID)
        deleted.account = card
        deleted.isSoftDeleted = true
        for tx in [inPeriod, withFee, outOfPeriod, repayment, deleted] { context.insert(tx) }
        try context.save()

        let statement = try CreditCardStatementProvider(context: context)
            .statement(for: card, asOf: date(2026, 8, 10), calendar: calendar)
        // 30000 + (10000+500) − 5000 = 35500；7/10 与软删流水不计
        #expect(statement.statementAmountMinorUnits == 35_500)
    }

    @Test func 周期内溢缴_账单金额下限为零() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let ledgerID = UUID()
        let card = makeCreditCard(context: context, statementDay: 15)
        let cash = Account(name: "现金", kind: .fund)
        context.insert(cash)
        let repayment = Transaction(kind: .transfer, amountMinorUnits: 50_000, occurredAt: date(2026, 7, 20), ledgerID: ledgerID)
        repayment.account = cash
        repayment.targetAccount = card
        context.insert(repayment)
        try context.save()

        let statement = try CreditCardStatementProvider(context: context)
            .statement(for: card, asOf: date(2026, 7, 25), calendar: calendar)
        #expect(statement.statementAmountMinorUnits == 0)
    }

    @Test func asOf之后但仍在账期内的未来消费不计账单与可用额度() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let card = makeCreditCard(context: context, statementDay: 15, limit: 100_000)
        let past = Transaction(
            kind: .expense,
            amountMinorUnits: 20_000,
            occurredAt: date(2026, 7, 20),
            ledgerID: UUID()
        )
        past.account = card
        let future = Transaction(
            kind: .expense,
            amountMinorUnits: 30_000,
            occurredAt: date(2026, 8, 1),
            ledgerID: UUID()
        )
        future.account = card
        context.insert(past)
        context.insert(future)
        try context.save()

        let statement = try CreditCardStatementProvider(context: context)
            .statement(for: card, asOf: date(2026, 7, 25), calendar: calendar)
        #expect(statement.statementAmountMinorUnits == 20_000)
        #expect(statement.availableCreditMinorUnits == 80_000)
    }

    @Test func 账单金额聚合溢出抛MoneyArithmeticError而非崩溃() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let card = makeCreditCard(context: context, statementDay: 15)
        for day in [20, 21] {
            let expense = Transaction(
                kind: .expense,
                amountMinorUnits: Int.max,
                occurredAt: date(2026, 7, day),
                ledgerID: UUID()
            )
            expense.account = card
            context.insert(expense)
        }
        try context.save()

        #expect(throws: MoneyArithmeticError.self) {
            try CreditCardStatementProvider(context: context)
                .statement(for: card, asOf: self.date(2026, 7, 25), calendar: self.calendar)
        }
    }

    // MARK: - 可用额度

    @Test func 独立卡可用额度等于额度减欠款() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let ledgerID = UUID()
        let card = makeCreditCard(context: context, statementDay: 15, limit: 100_000)
        let expense = Transaction(kind: .expense, amountMinorUnits: 30_000, occurredAt: date(2026, 7, 20), ledgerID: ledgerID)
        expense.account = card
        context.insert(expense)
        try context.save()

        let statement = try CreditCardStatementProvider(context: context)
            .statement(for: card, asOf: date(2026, 7, 25), calendar: calendar)
        #expect(statement.availableCreditMinorUnits == 70_000)
    }

    @Test func 无额度独立卡可用额度为nil() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let card = makeCreditCard(context: context, statementDay: 15)
        try context.save()

        let statement = try CreditCardStatementProvider(context: context)
            .statement(for: card, asOf: date(2026, 7, 25), calendar: calendar)
        #expect(statement.availableCreditMinorUnits == nil)
    }

    @Test func 池成员无子限额_剩余额度即池可用() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let ledgerID = UUID()
        let pool = CreditPool(name: "招商银行", totalLimitMinorUnits: 100_000)
        context.insert(pool)
        let card = makeCreditCard(context: context, statementDay: 15)
        card.creditPoolID = pool.uuid
        let sibling = makeCreditCard(context: context, statementDay: 15)
        sibling.creditPoolID = pool.uuid
        // 本卡欠 20000，同池另一卡欠 30000 → 池可用 = 100000 − 50000
        let mine = Transaction(kind: .expense, amountMinorUnits: 20_000, occurredAt: date(2026, 7, 20), ledgerID: ledgerID)
        mine.account = card
        let theirs = Transaction(kind: .expense, amountMinorUnits: 30_000, occurredAt: date(2026, 7, 21), ledgerID: ledgerID)
        theirs.account = sibling
        context.insert(mine)
        context.insert(theirs)
        try context.save()

        let statement = try CreditCardStatementProvider(context: context)
            .statement(for: card, asOf: date(2026, 7, 25), calendar: calendar)
        #expect(statement.availableCreditMinorUnits == 50_000)
    }

    @Test func 池成员有子限额_取子限额剩余与池可用较小者() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let ledgerID = UUID()
        let pool = CreditPool(name: "招商银行", totalLimitMinorUnits: 100_000)
        context.insert(pool)
        let card = makeCreditCard(context: context, statementDay: 15, limit: 30_000)
        card.creditPoolID = pool.uuid
        let expense = Transaction(kind: .expense, amountMinorUnits: 10_000, occurredAt: date(2026, 7, 20), ledgerID: ledgerID)
        expense.account = card
        context.insert(expense)
        try context.save()

        let statement = try CreditCardStatementProvider(context: context)
            .statement(for: card, asOf: date(2026, 7, 25), calendar: calendar)
        // 子限额剩余 = 30000 − 10000 = 20000 < 池可用 90000
        #expect(statement.availableCreditMinorUnits == 20_000)
    }

    // MARK: - 校验失败

    @Test func 非信用卡账户抛错() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let fund = Account(name: "现金", kind: .fund)
        context.insert(fund)
        try context.save()
        #expect(throws: CreditCardStatementProviderError.self) {
            try CreditCardStatementProvider(context: context).statement(for: fund, asOf: .now, calendar: calendar)
        }
    }

    @Test func 未设账单日抛错() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let card = makeCreditCard(context: context, statementDay: nil)
        try context.save()
        #expect(throws: CreditCardStatementProviderError.self) {
            try CreditCardStatementProvider(context: context).statement(for: card, asOf: .now, calendar: calendar)
        }
    }
}
