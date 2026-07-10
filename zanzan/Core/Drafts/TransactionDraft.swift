import Foundation

/// 流水表单草稿——入口校验 + 归一化（设计文档 5.4 命令层基础校验的 Draft 侧）。
struct TransactionDraft {
    var kind: TransactionKind = .expense
    var amountString: String = ""
    var occurredAt: Date = .now
    var note: String = ""
    var accountUUID: UUID? = nil
    var targetAccountUUID: UUID? = nil
    var categoryUUID: UUID? = nil
    var feeString: String = ""
    /// 外币流水对本位币（CNY）的汇率，十进制串；空串 = 未填（Service 层按 §5.4 预填/校验）
    var fxRateString: String = ""
    /// 跨币种转账到账金额（转入方币种计），十进制串；空串 = 未填
    var targetAmountString: String = ""

    struct Validated {
        let kind: TransactionKind
        let amountMinorUnits: Int
        let occurredAt: Date
        let note: String
        let accountUUID: UUID
        let targetAccountUUID: UUID?
        let categoryUUID: UUID?
        let feeMinorUnits: Int
        let fxRateToBase: Decimal?
        let targetAmountMinorUnits: Int?
    }

    func validated() throws -> Validated {
        guard let amount = MoneyAmount.minorUnits(fromDecimalString: amountString), amount > 0 else {
            throw TransactionDraftError.invalidAmount
        }
        guard let accountUUID else { throw TransactionDraftError.missingAccount }
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        // Draft 层只做格式/正数校验；币种相关语义校验（必填/归 nil）在 Service 层
        let fxRate = try parsedFxRate()

        switch kind {
        case .expense, .income:
            guard let categoryUUID else { throw TransactionDraftError.missingCategory }
            // 非转账 fee 恒 0、到账金额恒 nil（不变量，表单不展示，此处防御性归零）
            return Validated(
                kind: kind, amountMinorUnits: amount, occurredAt: occurredAt, note: note,
                accountUUID: accountUUID, targetAccountUUID: nil, categoryUUID: categoryUUID,
                feeMinorUnits: 0, fxRateToBase: fxRate, targetAmountMinorUnits: nil
            )
        case .transfer:
            guard let targetAccountUUID else { throw TransactionDraftError.missingTargetAccount }
            guard targetAccountUUID != accountUUID else { throw TransactionDraftError.sameTransferAccounts }
            let trimmedFee = feeString.trimmingCharacters(in: .whitespaces)
            var fee = 0
            if !trimmedFee.isEmpty {
                guard let parsed = MoneyAmount.minorUnits(fromDecimalString: trimmedFee) else {
                    throw TransactionDraftError.invalidFee
                }
                fee = parsed
            }
            return Validated(
                kind: kind, amountMinorUnits: amount, occurredAt: occurredAt, note: note,
                accountUUID: accountUUID, targetAccountUUID: targetAccountUUID, categoryUUID: nil,
                feeMinorUnits: fee, fxRateToBase: fxRate, targetAmountMinorUnits: try parsedTargetAmount()
            )
        }
    }

    /// 汇率串 → Decimal（定点解析，与 MoneyAmount 同用 en_US locale，禁 Double）；须 > 0
    private func parsedFxRate() throws -> Decimal? {
        let trimmed = fxRateString.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let rate = Decimal(string: trimmed, locale: Locale(identifier: "en_US")), rate > 0 else {
            throw TransactionDraftError.invalidFxRate
        }
        return rate
    }

    /// 到账金额串 → 分；须 > 0
    private func parsedTargetAmount() throws -> Int? {
        let trimmed = targetAmountString.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let amount = MoneyAmount.minorUnits(fromDecimalString: trimmed), amount > 0 else {
            throw TransactionDraftError.invalidTargetAmount
        }
        return amount
    }
}

enum TransactionDraftError: LocalizedError {
    case invalidAmount
    case missingAccount
    case missingCategory
    case missingTargetAccount
    case sameTransferAccounts
    case invalidFee
    case invalidFxRate
    case invalidTargetAmount

    var errorDescription: String? {
        switch self {
        case .invalidAmount: String(localized: "金额须为大于 0 的数字（最多两位小数）")
        case .missingAccount: String(localized: "请选择账户")
        case .missingCategory: String(localized: "请选择分类")
        case .missingTargetAccount: String(localized: "请选择转入账户")
        case .sameTransferAccounts: String(localized: "转出与转入账户不能相同")
        case .invalidFee: String(localized: "手续费格式不正确")
        case .invalidFxRate: String(localized: "汇率须为大于 0 的数字")
        case .invalidTargetAmount: String(localized: "到账金额须为大于 0 的数字（最多两位小数）")
        }
    }
}
