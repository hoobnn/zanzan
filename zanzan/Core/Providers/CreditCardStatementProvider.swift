import Foundation
import SwiftData

/// 信用卡本期账单投影结果（设计文档 5.2：账单金额/可用额度按 statementDay 派生，不落库）。
struct CreditCardStatement {
    /// 周期首日 00:00（上一账单日次日）
    let periodStart: Date
    /// 周期上界（本期账单日次日 00:00，半开区间；账单日当天计入本期）
    let periodEndExclusive: Date
    /// 本期账单金额 = 周期内净新增欠款（消费 + 费 − 还款转入），下限 0（周期内溢缴按 0 计）
    let statementAmountMinorUnits: Int
    /// 剩余可用额度：池成员按池口径（5.8），独立卡 = max(0, 额度 − 欠款)；
    /// 无池且未设额度时为 nil（无额度概念）
    let availableCreditMinorUnits: Int?
}

/// 信用卡账单周期只读投影：按 statementDay 切分本期周期并派生账单金额、剩余可用额度。
struct CreditCardStatementProvider {
    let context: ModelContext

    func statement(
        for account: Account,
        asOf referenceDate: Date = .now,
        calendar: Calendar = .current
    ) throws -> CreditCardStatement {
        guard account.kind == .credit else { throw CreditCardStatementProviderError.notCreditAccount }
        guard let statementDay = account.statementDay else {
            throw CreditCardStatementProviderError.missingStatementDay
        }

        let (periodStart, periodEndExclusive) = try Self.statementPeriod(
            containing: referenceDate, statementDay: statementDay, calendar: calendar
        )
        let statementAmount = try statementAmountMinorUnits(
            of: account, from: periodStart, to: periodEndExclusive
        )
        let availableCredit = try availableCreditMinorUnits(of: account)
        return CreditCardStatement(
            periodStart: periodStart,
            periodEndExclusive: periodEndExclusive,
            statementAmountMinorUnits: statementAmount,
            availableCreditMinorUnits: availableCredit
        )
    }

    // MARK: - 周期切分

    /// 本期周期 = (上一账单日, 本期账单日]，账单日当天计入本期；
    /// statementDay 超出当月天数时取当月最后一天（如 31 号遇 2 月 → 2/28 或 2/29）。
    static func statementPeriod(
        containing referenceDate: Date,
        statementDay: Int,
        calendar: Calendar
    ) throws -> (start: Date, endExclusive: Date) {
        guard (1...31).contains(statementDay) else {
            throw CreditCardStatementProviderError.invalidStatementDay
        }
        let referenceDay = calendar.startOfDay(for: referenceDate)
        var components = calendar.dateComponents([.year, .month], from: referenceDay)
        var endDate = try Self.statementDate(year: components.year!, month: components.month!, day: statementDay, calendar: calendar)
        if endDate < referenceDay {
            // 本月账单日已过，本期账单日落在下月
            components.month! += 1
            let normalized = calendar.date(from: components)!
            let next = calendar.dateComponents([.year, .month], from: normalized)
            endDate = try Self.statementDate(year: next.year!, month: next.month!, day: statementDay, calendar: calendar)
        }
        // 上一账单日 = 本期账单日前一个月的账单日（按各自月长独立收缩）
        let previousMonthAnchor = calendar.date(byAdding: .month, value: -1, to: endDate)!
        let previous = calendar.dateComponents([.year, .month], from: previousMonthAnchor)
        let previousStatementDate = try Self.statementDate(year: previous.year!, month: previous.month!, day: statementDay, calendar: calendar)
        let start = calendar.date(byAdding: .day, value: 1, to: previousStatementDate)!
        let endExclusive = calendar.date(byAdding: .day, value: 1, to: endDate)!
        return (start, endExclusive)
    }

    /// 某年某月的账单日 00:00；日号超出当月天数时收缩到月末。
    private static func statementDate(year: Int, month: Int, day: Int, calendar: Calendar) throws -> Date {
        guard let firstOfMonth = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let dayRange = calendar.range(of: .day, in: .month, for: firstOfMonth),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: min(day, dayRange.count)))
        else {
            throw CreditCardStatementProviderError.invalidStatementDay
        }
        return date
    }

    // MARK: - 派生金额

    /// 周期内净新增欠款：Σ 余额影响取反，下限 0（还款/溢缴冲抵消费）。
    private func statementAmountMinorUnits(of account: Account, from start: Date, to endExclusive: Date) throws -> Int {
        let uuid = account.uuid
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate {
                !$0.isSoftDeleted
                    && $0.occurredAt >= start && $0.occurredAt < endExclusive
                    && ($0.account?.uuid == uuid || $0.targetAccount?.uuid == uuid)
            }
        )
        let netDelta = try context.fetch(descriptor).reduce(0) { $0 + $1.balanceDeltaMinorUnits(for: uuid) }
        return max(0, -netDelta)
    }

    /// 剩余可用额度（5.8）：单卡欠款 = max(0, −派生余额)；
    /// 池成员无子限额即池可用，有子限额取 min(子限额 − 单卡欠款, 池可用)；
    /// 独立卡 = max(0, 额度 − 欠款)；池已删（读路径兜底）按独立额度口径。
    private func availableCreditMinorUnits(of account: Account) throws -> Int? {
        let debt = try max(0, -AccountBalanceProvider(context: context).balanceMinorUnits(of: account))
        let independentAvailable = account.creditLimitMinorUnits.map { max(0, $0 - debt) }
        guard let poolUUID = account.creditPoolID else { return independentAvailable }
        guard let poolOverview = try? CreditPoolProvider(context: context).overview(poolUUID: poolUUID) else {
            return independentAvailable // 池已软删/缺失：兜底回独立额度，不 crash（§4 同步合并兜底）
        }
        guard let subLimit = account.creditLimitMinorUnits else { return poolOverview.availableMinorUnits }
        return max(0, min(subLimit - debt, poolOverview.availableMinorUnits))
    }
}

enum CreditCardStatementProviderError: LocalizedError {
    case notCreditAccount
    case missingStatementDay
    case invalidStatementDay

    var errorDescription: String? {
        switch self {
        case .notCreditAccount: String(localized: "仅信用卡类账户有账单周期")
        case .missingStatementDay: String(localized: "该信用卡未设置账单日")
        case .invalidStatementDay: String(localized: "账单日须在 1–31 之间")
        }
    }
}
