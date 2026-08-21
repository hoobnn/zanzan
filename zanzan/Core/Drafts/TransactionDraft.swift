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
    var locationName: String = ""
    var locationLatitudeString: String = ""
    var locationLongitudeString: String = ""
    var isExcludedFromBudget: Bool = false
    var isExcludedFromStats: Bool = false

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
        let locationName: String
        let locationLatitude: Double?
        let locationLongitude: Double?
        let isExcludedFromBudget: Bool
        let isExcludedFromStats: Bool
    }

    func validated(allowZeroAmountForInstallmentCharge: Bool = false) throws -> Validated {
        guard let amount = MoneyAmount.minorUnits(fromDecimalString: amountString),
              amount > 0 || (allowZeroAmountForInstallmentCharge && kind == .transfer) else {
            throw TransactionDraftError.invalidAmount
        }
        guard let accountUUID else { throw TransactionDraftError.missingAccount }
        guard DraftLimits.occurredAtRange.contains(occurredAt) else {
            throw TransactionDraftError.occurredAtOutOfRange
        }
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note.count <= DraftLimits.maxNoteLength else { throw TransactionDraftError.noteTooLong }
        // Draft 层只做格式/正数校验；币种相关语义校验（必填/归 nil）在 Service 层
        let fxRate = try parsedFxRate()
        let location = try validatedLocation()

        switch kind {
        case .expense, .income:
            guard let categoryUUID else { throw TransactionDraftError.missingCategory }
            // 非转账 fee 恒 0、到账金额恒 nil（不变量，表单不展示，此处防御性归零）
            return Validated(
                kind: kind, amountMinorUnits: amount, occurredAt: occurredAt, note: note,
                accountUUID: accountUUID, targetAccountUUID: nil, categoryUUID: categoryUUID,
                feeMinorUnits: 0, fxRateToBase: fxRate, targetAmountMinorUnits: nil,
                locationName: location.name,
                locationLatitude: location.latitude,
                locationLongitude: location.longitude,
                isExcludedFromBudget: isExcludedFromBudget,
                isExcludedFromStats: isExcludedFromStats
            )
        case .transfer:
            guard let targetAccountUUID else { throw TransactionDraftError.missingTargetAccount }
            guard targetAccountUUID != accountUUID else { throw TransactionDraftError.sameTransferAccounts }
            let trimmedFee = feeString.trimmingCharacters(in: .whitespaces)
            var fee = 0
            if !trimmedFee.isEmpty {
                // fee ≥ 0 不变量：严格解析已拒负号/溢出环绕，此处显式兜底（CSV 注入负 fee = 造钱路径）
                guard let parsed = MoneyAmount.minorUnits(fromDecimalString: trimmedFee), parsed >= 0 else {
                    throw TransactionDraftError.invalidFee
                }
                fee = parsed
            }
            guard amount > 0 || fee > 0 else {
                throw TransactionDraftError.invalidAmount
            }
            return Validated(
                kind: kind, amountMinorUnits: amount, occurredAt: occurredAt, note: note,
                accountUUID: accountUUID, targetAccountUUID: targetAccountUUID, categoryUUID: nil,
                feeMinorUnits: fee, fxRateToBase: fxRate, targetAmountMinorUnits: try parsedTargetAmount(),
                locationName: location.name,
                locationLatitude: location.latitude,
                locationLongitude: location.longitude,
                isExcludedFromBudget: isExcludedFromBudget,
                isExcludedFromStats: isExcludedFromStats
            )
        }
    }

    private func validatedLocation() throws
        -> (name: String, latitude: Double?, longitude: Double?) {
        let name = locationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let latitude = locationLatitudeString.trimmingCharacters(in: .whitespaces)
        let longitude = locationLongitudeString.trimmingCharacters(in: .whitespaces)
        guard name.count <= DraftLimits.maxNameLength else {
            throw TransactionDraftError.locationNameTooLong
        }
        if name.isEmpty && latitude.isEmpty && longitude.isEmpty {
            return ("", nil, nil)
        }
        guard !name.isEmpty,
              let latitudeDecimal = MoneyAmount.strictDecimal(from: latitude),
              let longitudeDecimal = MoneyAmount.strictDecimal(from: longitude),
              (-90...90).contains(latitudeDecimal),
              (-180...180).contains(longitudeDecimal) else {
            throw TransactionDraftError.invalidLocation
        }
        return (
            name,
            NSDecimalNumber(decimal: latitudeDecimal).doubleValue,
            NSDecimalNumber(decimal: longitudeDecimal).doubleValue
        )
    }

    /// 汇率串 → Decimal（`MoneyAmount.strictDecimal` 严格白名单解析，拒逗号/科学计数法，禁 Double）；须 > 0
    private func parsedFxRate() throws -> Decimal? {
        let trimmed = fxRateString.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let maxRate = Decimal(Int.max) / Decimal(MoneyAmount.maxAbsoluteMinorUnits)
        guard let rate = MoneyAmount.strictDecimal(from: trimmed),
              rate > 0,
              rate <= maxRate else {
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
    case noteTooLong
    case occurredAtOutOfRange
    case locationNameTooLong
    case invalidLocation

    var errorDescription: String? {
        switch self {
        case .invalidAmount: ZanzanLocalization.string( "金额须为大于 0 的数字（最多两位小数）")
        case .missingAccount: ZanzanLocalization.string( "请选择账户")
        case .missingCategory: ZanzanLocalization.string( "请选择分类")
        case .missingTargetAccount: ZanzanLocalization.string( "请选择转入账户")
        case .sameTransferAccounts: ZanzanLocalization.string( "转出与转入账户不能相同")
        case .invalidFee: ZanzanLocalization.string( "手续费格式不正确")
        case .invalidFxRate: ZanzanLocalization.string( "汇率须为大于 0 的数字")
        case .invalidTargetAmount: ZanzanLocalization.string( "到账金额须为大于 0 的数字（最多两位小数）")
        case .noteTooLong: ZanzanLocalization.string( "备注不能超过 \(DraftLimits.maxNoteLength) 字")
        case .occurredAtOutOfRange: ZanzanLocalization.string( "记账时间超出可记账范围")
        case .locationNameTooLong: ZanzanLocalization.string( "地点名称不能超过 \(DraftLimits.maxNameLength) 字")
        case .invalidLocation: ZanzanLocalization.string( "地点名称、纬度和经度须同时填写，且坐标范围有效")
        }
    }
}
