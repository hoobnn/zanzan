import Foundation

/// 账户表单草稿——入口校验 + 归一化。信用字段仅 credit 类保留（设计文档 5.2）。
struct AccountDraft {
    var name: String = ""
    var subtitle: String = ""
    var kind: AccountKind = .fund
    var initialBalanceString: String = "0"
    var creditLimitString: String = ""
    var statementDay: Int? = nil
    var paymentDueDay: Int? = nil
    var note: String = ""
    var isIncludedInNetWorth: Bool = true

    struct Validated {
        let name: String
        let subtitle: String
        let kind: AccountKind
        let initialBalanceMinorUnits: Int
        let creditLimitMinorUnits: Int?
        let statementDay: Int?
        let paymentDueDay: Int?
        let note: String
        let isIncludedInNetWorth: Bool
    }

    func validated() throws -> Validated {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AccountDraftError.emptyName }
        guard let initialBalance = MoneyAmount.signedMinorUnits(fromDecimalString: initialBalanceString) else {
            throw AccountDraftError.invalidInitialBalance
        }
        // 非 credit 类归一化清空信用字段（表单只对 credit 展示这些字段）
        var creditLimit: Int? = nil
        var statementDay: Int? = nil
        var paymentDueDay: Int? = nil
        if kind == .credit {
            if !creditLimitString.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let limit = MoneyAmount.minorUnits(fromDecimalString: creditLimitString) else {
                    throw AccountDraftError.invalidCreditLimit
                }
                creditLimit = limit
            }
            statementDay = self.statementDay
            paymentDueDay = self.paymentDueDay
            for day in [statementDay, paymentDueDay].compactMap({ $0 }) {
                guard (1...28).contains(day) else { throw AccountDraftError.invalidDayOfMonth }
            }
        }
        return Validated(
            name: name,
            subtitle: subtitle.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            initialBalanceMinorUnits: initialBalance,
            creditLimitMinorUnits: creditLimit,
            statementDay: statementDay,
            paymentDueDay: paymentDueDay,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            isIncludedInNetWorth: isIncludedInNetWorth
        )
    }
}

extension AccountDraft {
    /// 编辑表单回填（账户管理页/资产页共用）。
    init(account: StoredAccount) {
        self.init()
        name = account.name
        subtitle = account.subtitle
        kind = account.kind ?? .fund
        initialBalanceString = MoneyAmount.decimalString(fromMinorUnits: account.initialBalanceMinorUnits)
        creditLimitString = account.creditLimitMinorUnits.map { MoneyAmount.decimalString(fromMinorUnits: $0) } ?? ""
        statementDay = account.statementDay
        paymentDueDay = account.paymentDueDay
        note = account.note
        isIncludedInNetWorth = account.isIncludedInNetWorth
    }
}

enum AccountDraftError: LocalizedError {
    case emptyName
    case invalidInitialBalance
    case invalidCreditLimit
    case invalidDayOfMonth

    var errorDescription: String? {
        switch self {
        case .emptyName: String(localized: "账户名不能为空")
        case .invalidInitialBalance: String(localized: "期初余额格式不正确")
        case .invalidCreditLimit: String(localized: "信用额度格式不正确")
        case .invalidDayOfMonth: String(localized: "账单日/还款日须在 1–28 之间")
        }
    }
}
