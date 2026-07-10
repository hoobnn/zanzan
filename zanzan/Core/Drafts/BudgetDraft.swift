import Foundation

/// 预算表单草稿——入口校验 + 结构约束（设计文档 5.7）。
/// 金额为最小货币单位整数且必须为正；periodYear/periodMonth 同空同有（nil = 模板行）。
/// categoryID 的存在性/支出侧/一级校验属命令层（需查库）。
struct BudgetDraft {
    var ledgerID: UUID
    /// nil = 总预算；非 nil → 支出侧一级分类
    var categoryID: UUID? = nil
    /// nil = 模板行（对未来月份生效的默认额）
    var periodYear: Int? = nil
    var periodMonth: Int? = nil
    var amountMinorUnits: Int = 0

    struct Validated {
        let ledgerID: UUID
        let categoryID: UUID?
        let periodYear: Int?
        let periodMonth: Int?
        let amountMinorUnits: Int
    }

    func validated() throws -> Validated {
        guard amountMinorUnits > 0 else { throw BudgetDraftError.nonPositiveAmount }
        guard (periodYear == nil) == (periodMonth == nil) else { throw BudgetDraftError.periodMismatch }
        if let periodMonth {
            guard (1...12).contains(periodMonth) else { throw BudgetDraftError.invalidMonth }
        }
        return Validated(
            ledgerID: ledgerID,
            categoryID: categoryID,
            periodYear: periodYear,
            periodMonth: periodMonth,
            amountMinorUnits: amountMinorUnits
        )
    }
}

enum BudgetDraftError: LocalizedError {
    case nonPositiveAmount
    case periodMismatch
    case invalidMonth

    var errorDescription: String? {
        switch self {
        case .nonPositiveAmount: String(localized: "预算金额必须大于零")
        case .periodMismatch: String(localized: "预算年份与月份必须同时填写或同时留空")
        case .invalidMonth: String(localized: "预算月份必须在 1 到 12 之间")
        }
    }
}
