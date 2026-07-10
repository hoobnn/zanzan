import Foundation
import SwiftData

/// 预算写路径命令（设计文档 5.7 / §4 软删语义）。不变量：
/// 同 (ledgerID, categoryID, periodYear, periodMonth) 维度至多一条活跃行；
/// categoryID 非空时必须指向活跃的支出侧一级分类；金额恒正。
struct BudgetService {
    let context: ModelContext

    @discardableResult
    func createBudget(_ draft: BudgetDraft) throws -> Budget {
        let v = try draft.validated()
        try validateCategory(v.categoryID)
        guard try activeBudget(
            ledgerID: v.ledgerID, categoryID: v.categoryID,
            year: v.periodYear, month: v.periodMonth
        ) == nil else { throw BudgetServiceError.duplicateBudget }
        let budget = Budget(ledgerID: v.ledgerID, amountMinorUnits: v.amountMinorUnits)
        budget.categoryID = v.categoryID
        budget.periodYear = v.periodYear
        budget.periodMonth = v.periodMonth
        context.insert(budget)
        try context.save()
        return budget
    }

    /// 改额度：模板行 = 改默认预算（已物化的历史月份不受影响）；月度行 = 只改当月。
    /// 维度字段（账本/分类/年月）是行身份，不提供修改。
    func updateAmount(uuid: UUID, amountMinorUnits: Int) throws {
        guard amountMinorUnits > 0 else { throw BudgetDraftError.nonPositiveAmount }
        let budget = try fetchActiveBudget(uuid)
        budget.amountMinorUnits = amountMinorUnits
        budget.updatedAt = .now
        try context.save()
    }

    /// 软删（归档）：模板行删除后不再物化未来月份；既有月度行保留，历史口径不篡改。
    func softDeleteBudget(uuid: UUID) throws {
        let budget = try fetchActiveBudget(uuid)
        budget.isSoftDeleted = true
        budget.updatedAt = .now
        try context.save()
    }

    /// 按月物化：把该账本全部活跃模板行复制为 (year, month) 实体行。
    /// 幂等：同维度已有活跃月度行（含用户改过额度的）一律跳过，不重复生成、不覆盖。
    @discardableResult
    func materialize(ledgerID: UUID, year: Int, month: Int) throws -> [Budget] {
        guard (1...12).contains(month) else { throw BudgetServiceError.invalidMonth }
        let templates = try context.fetch(
            FetchDescriptor<Budget>(predicate: #Predicate {
                !$0.isSoftDeleted && $0.ledgerID == ledgerID && $0.periodYear == nil
            })
        )
        var created: [Budget] = []
        for template in templates {
            let categoryID = template.categoryID
            let hasMonthlyRow = try activeBudget(
                ledgerID: ledgerID, categoryID: categoryID, year: year, month: month
            ) != nil
            if hasMonthlyRow { continue }
            let monthly = Budget(ledgerID: ledgerID, amountMinorUnits: template.amountMinorUnits)
            monthly.categoryID = categoryID
            monthly.periodYear = year
            monthly.periodMonth = month
            context.insert(monthly)
            created.append(monthly)
        }
        if !created.isEmpty { try context.save() }
        return created
    }

    // MARK: - 私有

    /// 分类预算校验：分类存在且活跃、支出侧、一级（设计文档 5.7）。
    private func validateCategory(_ categoryID: UUID?) throws {
        guard let categoryID else { return } // nil = 总预算
        let descriptor = FetchDescriptor<Category>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == categoryID }
        )
        guard let category = try context.fetch(descriptor).first else {
            throw BudgetServiceError.categoryNotFound
        }
        guard category.kind == .expense else { throw BudgetServiceError.categoryNotExpense }
        guard category.parentID == nil else { throw BudgetServiceError.categoryNotTopLevel }
    }

    private func activeBudget(
        ledgerID: UUID, categoryID: UUID?, year: Int?, month: Int?
    ) throws -> Budget? {
        try context.fetch(
            FetchDescriptor<Budget>(predicate: #Predicate {
                !$0.isSoftDeleted && $0.ledgerID == ledgerID
                    && $0.categoryID == categoryID
                    && $0.periodYear == year && $0.periodMonth == month
            })
        ).first
    }

    private func fetchActiveBudget(_ uuid: UUID) throws -> Budget {
        let descriptor = FetchDescriptor<Budget>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        )
        guard let budget = try context.fetch(descriptor).first else {
            throw BudgetServiceError.budgetNotFound
        }
        return budget
    }
}

enum BudgetServiceError: LocalizedError {
    case budgetNotFound
    case categoryNotFound
    case categoryNotExpense
    case categoryNotTopLevel
    case duplicateBudget
    case invalidMonth

    var errorDescription: String? {
        switch self {
        case .budgetNotFound: String(localized: "预算不存在或已删除")
        case .categoryNotFound: String(localized: "预算分类不存在或已删除")
        case .categoryNotExpense: String(localized: "只有支出分类可以设置预算")
        case .categoryNotTopLevel: String(localized: "预算只能设在一级分类上，子分类金额会汇入父类")
        case .duplicateBudget: String(localized: "该分类的预算已存在，可直接修改额度")
        case .invalidMonth: String(localized: "无效的预算月份")
        }
    }
}
