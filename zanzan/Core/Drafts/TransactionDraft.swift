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

    struct Validated {
        let kind: TransactionKind
        let amountMinorUnits: Int
        let occurredAt: Date
        let note: String
        let accountUUID: UUID
        let targetAccountUUID: UUID?
        let categoryUUID: UUID?
        let feeMinorUnits: Int
    }

    func validated() throws -> Validated {
        guard let amount = MoneyAmount.minorUnits(fromDecimalString: amountString), amount > 0 else {
            throw TransactionDraftError.invalidAmount
        }
        guard let accountUUID else { throw TransactionDraftError.missingAccount }
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)

        switch kind {
        case .expense, .income:
            guard let categoryUUID else { throw TransactionDraftError.missingCategory }
            // 非转账 fee 恒 0（不变量，表单不展示手续费，此处防御性归零）
            return Validated(
                kind: kind, amountMinorUnits: amount, occurredAt: occurredAt, note: note,
                accountUUID: accountUUID, targetAccountUUID: nil, categoryUUID: categoryUUID,
                feeMinorUnits: 0
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
                feeMinorUnits: fee
            )
        }
    }
}

enum TransactionDraftError: LocalizedError {
    case invalidAmount
    case missingAccount
    case missingCategory
    case missingTargetAccount
    case sameTransferAccounts
    case invalidFee

    var errorDescription: String? {
        switch self {
        case .invalidAmount: "金额须为大于 0 的数字（最多两位小数）"
        case .missingAccount: "请选择账户"
        case .missingCategory: "请选择分类"
        case .missingTargetAccount: "请选择转入账户"
        case .sameTransferAccounts: "转出与转入账户不能相同"
        case .invalidFee: "手续费格式不正确"
        }
    }
}
