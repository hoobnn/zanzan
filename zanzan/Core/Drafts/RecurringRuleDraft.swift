import Foundation

/// 周期记账表单草稿——入口校验 + 归一化（设计文档 5.11）。
/// recurrenceDays 语义：weekly 取 `Calendar.weekday`（1=周日…7=周六）；monthly 取 1...31，
/// 值大于当月天数时收缩到月末（收缩发生在命令层触发日计算，见 RecurringRuleService）。
/// 引用存在性（账本/账户/分类/标签）与方向校验属命令层（需查库）。
struct RecurringRuleDraft {
    var name: String = ""
    var frequency: RecurrenceFrequency = .monthly
    var interval: Int = 1
    /// 空数组时 weekly/monthly 从 startAt 推导（周几/几号），daily 不适用恒空
    var recurrenceDays: [Int] = []
    /// 生效起点（业务时间一律由调用方注入，禁止在逻辑层取当前时钟）
    var startAt: Date
    var endAt: Date? = nil
    var templateKind: TransactionKind = .expense
    var templateLedgerID: UUID
    var amountString: String = ""
    var templateAccountID: UUID? = nil
    var templateTargetAccountID: UUID? = nil
    var templateCategoryID: UUID? = nil
    var templateTagIDs: [UUID] = []
    var templateNote: String = ""

    struct Validated {
        let name: String
        let frequency: RecurrenceFrequency
        let interval: Int
        let recurrenceDays: [Int]
        let startAt: Date
        let endAt: Date?
        let templateKind: TransactionKind
        let templateLedgerID: UUID
        let templateAmountMinorUnits: Int
        let templateAccountID: UUID
        let templateTargetAccountID: UUID?
        let templateCategoryID: UUID?
        let templateTagIDs: [UUID]
        let templateNote: String
    }

    func validated() throws -> Validated {
        let name = self.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RecurringRuleDraftError.emptyName }
        guard interval >= 1 else { throw RecurringRuleDraftError.invalidInterval }
        if let endAt, endAt < startAt { throw RecurringRuleDraftError.endBeforeStart }
        guard let amount = MoneyAmount.minorUnits(fromDecimalString: amountString), amount > 0 else {
            throw RecurringRuleDraftError.invalidAmount
        }
        guard let accountID = templateAccountID else { throw RecurringRuleDraftError.missingAccount }
        let days = try normalizedRecurrenceDays()
        let tagIDs = dedupedTagIDs()
        let note = templateNote.trimmingCharacters(in: .whitespacesAndNewlines)

        switch templateKind {
        case .expense, .income:
            guard let categoryID = templateCategoryID else { throw RecurringRuleDraftError.missingCategory }
            // 非转账不该有转入方，防御性归 nil
            return Validated(
                name: name, frequency: frequency, interval: interval, recurrenceDays: days,
                startAt: startAt, endAt: endAt, templateKind: templateKind,
                templateLedgerID: templateLedgerID, templateAmountMinorUnits: amount,
                templateAccountID: accountID, templateTargetAccountID: nil,
                templateCategoryID: categoryID, templateTagIDs: tagIDs, templateNote: note
            )
        case .transfer:
            guard let targetID = templateTargetAccountID else { throw RecurringRuleDraftError.missingTargetAccount }
            guard targetID != accountID else { throw RecurringRuleDraftError.sameTransferAccounts }
            // 转账不挂分类，防御性归 nil
            return Validated(
                name: name, frequency: frequency, interval: interval, recurrenceDays: days,
                startAt: startAt, endAt: endAt, templateKind: templateKind,
                templateLedgerID: templateLedgerID, templateAmountMinorUnits: amount,
                templateAccountID: accountID, templateTargetAccountID: targetID,
                templateCategoryID: nil, templateTagIDs: tagIDs, templateNote: note
            )
        }
    }

    // MARK: - 私有

    /// 触发日归一化：去重升序；weekly/monthly 留空时从 startAt 推导；daily 无触发日概念恒清空。
    private func normalizedRecurrenceDays() throws -> [Int] {
        let calendar = Calendar.current
        switch frequency {
        case .daily:
            return []
        case .weekly:
            let days = recurrenceDays.isEmpty
                ? [calendar.component(.weekday, from: startAt)]
                : recurrenceDays
            guard days.allSatisfy({ (1...7).contains($0) }) else {
                throw RecurringRuleDraftError.invalidRecurrenceDays
            }
            return Set(days).sorted()
        case .monthly:
            let days = recurrenceDays.isEmpty
                ? [calendar.component(.day, from: startAt)]
                : recurrenceDays
            guard days.allSatisfy({ (1...31).contains($0) }) else {
                throw RecurringRuleDraftError.invalidRecurrenceDays
            }
            return Set(days).sorted()
        }
    }

    /// 标签去重（保持原顺序）
    private func dedupedTagIDs() -> [UUID] {
        var seen = Set<UUID>()
        return templateTagIDs.filter { seen.insert($0).inserted }
    }
}

enum RecurringRuleDraftError: LocalizedError {
    case emptyName
    case invalidInterval
    case invalidRecurrenceDays
    case endBeforeStart
    case invalidAmount
    case missingAccount
    case missingCategory
    case missingTargetAccount
    case sameTransferAccounts

    var errorDescription: String? {
        switch self {
        case .emptyName: String(localized: "请输入计划名称")
        case .invalidInterval: String(localized: "重复间隔必须大于等于 1")
        case .invalidRecurrenceDays: String(localized: "触发日超出有效范围")
        case .endBeforeStart: String(localized: "截止时间不能早于开始时间")
        case .invalidAmount: String(localized: "金额须为大于 0 的数字（最多两位小数）")
        case .missingAccount: String(localized: "请选择账户")
        case .missingCategory: String(localized: "请选择分类")
        case .missingTargetAccount: String(localized: "请选择转入账户")
        case .sameTransferAccounts: String(localized: "转出与转入账户不能相同")
        }
    }
}
