import Foundation

/// 账户表单草稿——入口校验 + 归一化。信用字段仅 credit 类保留（设计文档 5.2）。
struct AccountDraft {
    var name: String = ""
    var subtitle: String = ""
    var kind: AccountKind = .fund
    /// 币种代码（ISO 4217，三位大写字母）；归一化大写
    var currencyCode: String = "CNY"
    var initialBalanceString: String = "0"
    var creditLimitString: String = ""
    var statementDay: Int? = nil
    var paymentDueDay: Int? = nil
    var note: String = ""
    var isIncludedInNetWorth: Bool = true
    var isSelectableForRecord: Bool = true

    struct Validated {
        let name: String
        let subtitle: String
        let kind: AccountKind
        let currencyCode: String
        let initialBalanceMinorUnits: Int
        let creditLimitMinorUnits: Int?
        let statementDay: Int?
        let paymentDueDay: Int?
        let note: String
        let isIncludedInNetWorth: Bool
        let isSelectableForRecord: Bool
    }

    func validated() throws -> Validated {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AccountDraftError.emptyName }
        guard name.count <= DraftLimits.maxNameLength else { throw AccountDraftError.nameTooLong }
        let subtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard subtitle.count <= DraftLimits.maxNameLength else { throw AccountDraftError.subtitleTooLong }
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note.count <= DraftLimits.maxNoteLength else { throw AccountDraftError.noteTooLong }
        // ISO 4217 格式校验：归一化大写后须为三位大写字母
        let currencyCode = currencyCode.trimmingCharacters(in: .whitespaces).uppercased()
        guard currencyCode.count == 3, currencyCode.allSatisfy({ ("A"..."Z").contains($0) }) else {
            throw AccountDraftError.invalidCurrencyCode
        }
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
            subtitle: subtitle,
            kind: kind,
            currencyCode: currencyCode,
            initialBalanceMinorUnits: initialBalance,
            creditLimitMinorUnits: creditLimit,
            statementDay: statementDay,
            paymentDueDay: paymentDueDay,
            note: note,
            isIncludedInNetWorth: isIncludedInNetWorth,
            isSelectableForRecord: isSelectableForRecord
        )
    }
}

extension AccountDraft {
    /// 编辑表单回填（账户管理页/资产页共用）。
    init(account: Account) {
        self.init()
        name = account.name
        subtitle = account.subtitle
        kind = account.kind ?? .fund
        currencyCode = account.currencyCode
        initialBalanceString = MoneyAmount.decimalString(fromMinorUnits: account.initialBalanceMinorUnits)
        creditLimitString = account.creditLimitMinorUnits.map { MoneyAmount.decimalString(fromMinorUnits: $0) } ?? ""
        statementDay = account.statementDay
        paymentDueDay = account.paymentDueDay
        note = account.note
        isIncludedInNetWorth = account.isIncludedInNetWorth
        isSelectableForRecord = account.isSelectableForRecord
    }
}

enum AccountDraftError: LocalizedError {
    case emptyName
    case nameTooLong
    case subtitleTooLong
    case noteTooLong
    case invalidCurrencyCode
    case invalidInitialBalance
    case invalidCreditLimit
    case invalidDayOfMonth

    var errorDescription: String? {
        switch self {
        case .emptyName: ZanzanLocalization.string( "账户名不能为空")
        case .nameTooLong: ZanzanLocalization.string( "账户名不能超过 \(DraftLimits.maxNameLength) 字")
        case .subtitleTooLong: ZanzanLocalization.string( "账户副标题不能超过 \(DraftLimits.maxNameLength) 字")
        case .noteTooLong: ZanzanLocalization.string( "备注不能超过 \(DraftLimits.maxNoteLength) 字")
        case .invalidCurrencyCode: ZanzanLocalization.string( "币种代码须为 3 位大写字母（ISO 4217）")
        case .invalidInitialBalance: ZanzanLocalization.string( "期初余额格式不正确")
        case .invalidCreditLimit: ZanzanLocalization.string( "信用额度格式不正确")
        case .invalidDayOfMonth: ZanzanLocalization.string( "账单日/还款日须在 1–28 之间")
        }
    }
}
