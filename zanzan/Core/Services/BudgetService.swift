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
        try ensureActiveLedger(v.ledgerID)
        try validatePeriod(year: v.periodYear, month: v.periodMonth)
        try validateCategory(v.categoryID, ledgerID: v.ledgerID)
        guard try activeBudget(
            ledgerID: v.ledgerID, categoryID: v.categoryID,
            year: v.periodYear, month: v.periodMonth
        ) == nil else { throw BudgetServiceError.duplicateBudget }
        let budget = Budget(ledgerID: v.ledgerID, amountMinorUnits: v.amountMinorUnits)
        budget.categoryID = v.categoryID
        budget.periodYear = v.periodYear
        budget.periodMonth = v.periodMonth
        context.insert(budget)
        try context.zanzanSave()
        return budget
    }

    /// 改额度：模板行 = 改默认预算（已物化的历史月份不受影响）；月度行 = 只改当月。
    /// 维度字段（账本/分类/年月）是行身份，不提供修改。
    func updateAmount(uuid: UUID, amountMinorUnits: Int) throws {
        guard amountMinorUnits > 0 else { throw BudgetDraftError.nonPositiveAmount }
        guard amountMinorUnits <= MoneyAmount.maxAbsoluteMinorUnits else {
            throw BudgetDraftError.amountTooLarge
        }
        let budget = try fetchActiveBudget(uuid)
        budget.amountMinorUnits = amountMinorUnits
        budget.updatedAt = .now
        try context.zanzanSave()
    }

    /// 软删（归档）：模板行删除后不再物化未来月份；既有月度行保留，历史口径不篡改。
    func softDeleteBudget(uuid: UUID) throws {
        let budget = try fetchActiveBudget(uuid)
        budget.isSoftDeleted = true
        budget.updatedAt = .now
        try context.zanzanSave()
    }

    /// 撤销软删（§4 撤销恢复按相反方向执行）：恢复前校验引用活跃（账本/分类）
    /// 与维度唯一性（同维度已有活跃行则阻断），违例不落任何改动。
    func undoSoftDeleteBudget(uuid: UUID) throws {
        let budget = try fetchBudget(uuid, includeDeleted: true)
        guard budget.isSoftDeleted else { return } // 幂等：已活跃即无事可做
        try ensureActiveLedger(budget.ledgerID)
        try validatePeriod(year: budget.periodYear, month: budget.periodMonth)
        try validateCategory(budget.categoryID, ledgerID: budget.ledgerID)
        guard try activeBudget(
            ledgerID: budget.ledgerID, categoryID: budget.categoryID,
            year: budget.periodYear, month: budget.periodMonth
        ) == nil else { throw BudgetServiceError.duplicateBudget }
        budget.isSoftDeleted = false
        budget.updatedAt = .now
        try context.zanzanSave()
    }

    /// 主实体（账本/分类）恢复时级联恢复其名下软删预算行（§4 撤销恢复按相反方向执行）。
    /// 不 save，随调用方业务写一并提交（invalidateSnapshots 同款约定）。
    /// ponytail: 无删除来源标记，无法区分「主实体级联软删的行」与「用户此前手动删的行」，
    /// 全部尝试恢复（restoreSettlement 同款天花板，需精确可将来在 Budget 加删除来源标记）；
    /// 靠两道守卫兜住不变量：引用账本/分类须活跃、同维度已有活跃行则跳过（updatedAt 新者优先）。
    static func restoreSoftDeletedBudgets(_ budgets: [Budget], context: ModelContext) throws {
        for budget in budgets.sorted(by: { $0.updatedAt > $1.updatedAt }) where budget.isSoftDeleted {
            guard try isReferenceActive(budget, context: context),
                  try !hasActiveRow(inDimensionOf: budget, context: context) else { continue }
            budget.isSoftDeleted = false
            budget.updatedAt = .now
        }
    }

    /// 按月物化：把该账本全部活跃模板行复制为 (year, month) 实体行。
    /// 幂等：同维度该月存在任意行（含软删——用户删掉月度行即否决该月）一律跳过，
    /// 不重复生成、不覆盖、不复活（与周期规则按既有产出去重的口径一致）。
    @discardableResult
    func materialize(ledgerID: UUID, year: Int, month: Int) throws -> [Budget] {
        try ensureActiveLedger(ledgerID)
        try validatePeriod(year: year, month: month)
        let templates = try context.fetch(
            FetchDescriptor<Budget>(predicate: #Predicate {
                !$0.isSoftDeleted && $0.ledgerID == ledgerID && $0.periodYear == nil
            })
        )
        // 全量校验后才开始插入，避免某条模板引用失效时留下半批月度行。
        for template in templates {
            try validatePeriod(year: template.periodYear, month: template.periodMonth)
            try validateCategory(template.categoryID, ledgerID: ledgerID)
        }
        var created: [Budget] = []
        for template in templates {
            let categoryID = template.categoryID
            if try hasAnyMonthlyRow(
                ledgerID: ledgerID, categoryID: categoryID, year: year, month: month
            ) { continue }
            let monthly = Budget(ledgerID: ledgerID, amountMinorUnits: template.amountMinorUnits)
            monthly.categoryID = categoryID
            monthly.periodYear = year
            monthly.periodMonth = month
            context.insert(monthly)
            created.append(monthly)
        }
        if !created.isEmpty { try context.zanzanSave() }
        return created
    }

    // MARK: - 私有

    /// 级联恢复守卫一：预算引用的账本活跃、分类（若有）活跃。
    private static func isReferenceActive(_ budget: Budget, context: ModelContext) throws -> Bool {
        guard isPeriodValid(year: budget.periodYear, month: budget.periodMonth) else {
            return false
        }
        let ledgerID = budget.ledgerID
        guard let ledger = try context.fetch(
            FetchDescriptor<Ledger>(predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == ledgerID })
        ).first, !ledger.isArchived else { return false }
        guard let categoryID = budget.categoryID else { return true }
        guard let category = try context.fetch(
            FetchDescriptor<Category>(predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == categoryID })
        ).first else { return false }
        return !category.isArchived
            && category.kind == .expense
            && category.parentID == nil
            && (category.ledgerID == nil || category.ledgerID == budget.ledgerID)
    }

    /// 级联恢复守卫二：同维度是否已有活跃行（含本轮循环里刚恢复的，上下文内可见）。
    private static func hasActiveRow(inDimensionOf budget: Budget, context: ModelContext) throws -> Bool {
        let ledgerID = budget.ledgerID
        let categoryID = budget.categoryID
        let year = budget.periodYear
        let month = budget.periodMonth
        return try context.fetchCount(
            FetchDescriptor<Budget>(predicate: #Predicate {
                !$0.isSoftDeleted && $0.ledgerID == ledgerID && $0.categoryID == categoryID
                    && $0.periodYear == year && $0.periodMonth == month
            })
        ) > 0
    }

    private func ensureActiveLedger(_ uuid: UUID) throws {
        guard let ledger = try context.fetch(
            FetchDescriptor<Ledger>(predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid })
        ).first else {
            throw BudgetServiceError.ledgerNotFound
        }
        guard !ledger.isArchived else { throw BudgetServiceError.ledgerArchived }
    }

    private func validatePeriod(year: Int?, month: Int?) throws {
        guard (year == nil) == (month == nil) else {
            throw BudgetServiceError.periodMismatch
        }
        if let year {
            guard DraftLimits.budgetYearRange.contains(year) else {
                throw BudgetServiceError.invalidYear
            }
        }
        if let month {
            guard (1...12).contains(month) else {
                throw BudgetServiceError.invalidMonth
            }
        }
    }

    private static func isPeriodValid(year: Int?, month: Int?) -> Bool {
        guard (year == nil) == (month == nil) else { return false }
        if let year, !DraftLimits.budgetYearRange.contains(year) { return false }
        if let month, !(1...12).contains(month) { return false }
        return true
    }

    /// 分类预算校验：分类存在且活跃、支出侧、一级（设计文档 5.7）。
    private func validateCategory(_ categoryID: UUID?, ledgerID: UUID) throws {
        guard let categoryID else { return } // nil = 总预算
        let descriptor = FetchDescriptor<Category>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == categoryID }
        )
        guard let category = try context.fetch(descriptor).first else {
            throw BudgetServiceError.categoryNotFound
        }
        guard !category.isArchived else { throw BudgetServiceError.categoryArchived }
        guard category.kind == .expense else { throw BudgetServiceError.categoryNotExpense }
        guard category.parentID == nil else { throw BudgetServiceError.categoryNotTopLevel }
        guard category.ledgerID == nil || category.ledgerID == ledgerID else {
            throw BudgetServiceError.categoryLedgerMismatch
        }
    }

    /// 该维度当月是否已有任意行（含软删）。物化去重专用——软删行也算"该月已否决"。
    private func hasAnyMonthlyRow(
        ledgerID: UUID, categoryID: UUID?, year: Int, month: Int
    ) throws -> Bool {
        try context.fetchCount(
            FetchDescriptor<Budget>(predicate: #Predicate {
                $0.ledgerID == ledgerID && $0.categoryID == categoryID
                    && $0.periodYear == year && $0.periodMonth == month
            })
        ) > 0
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
        try fetchBudget(uuid, includeDeleted: false)
    }

    private func fetchBudget(_ uuid: UUID, includeDeleted: Bool) throws -> Budget {
        let predicate: Predicate<Budget> = includeDeleted
            ? #Predicate { $0.uuid == uuid }
            : #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        guard let budget = try context.fetch(FetchDescriptor<Budget>(predicate: predicate)).first else {
            throw BudgetServiceError.budgetNotFound
        }
        return budget
    }
}

enum BudgetServiceError: LocalizedError {
    case budgetNotFound
    case ledgerNotFound
    case ledgerArchived
    case categoryNotFound
    case categoryArchived
    case categoryNotExpense
    case categoryNotTopLevel
    case categoryLedgerMismatch
    case duplicateBudget
    case periodMismatch
    case invalidYear
    case invalidMonth

    var errorDescription: String? {
        switch self {
        case .budgetNotFound: ZanzanLocalization.string( "预算不存在或已删除")
        case .ledgerNotFound: ZanzanLocalization.string( "账本不存在或已删除")
        case .ledgerArchived: ZanzanLocalization.string( "账本已归档，请先取消归档再使用")
        case .categoryNotFound: ZanzanLocalization.string( "预算分类不存在或已删除")
        case .categoryArchived: ZanzanLocalization.string( "分类已归档，请先取消归档再使用")
        case .categoryNotExpense: ZanzanLocalization.string( "只有支出分类可以设置预算")
        case .categoryNotTopLevel: ZanzanLocalization.string( "预算只能设在一级分类上，子分类金额会汇入父类")
        case .categoryLedgerMismatch: ZanzanLocalization.string( "只能为全局分类或本账本分类设置预算")
        case .duplicateBudget: ZanzanLocalization.string( "该分类的预算已存在，可直接修改额度")
        case .periodMismatch: ZanzanLocalization.string( "预算年份与月份必须同时填写或同时留空")
        case .invalidYear: ZanzanLocalization.string(
            "预算年份必须在 \(DraftLimits.budgetYearRange.lowerBound) 到 \(DraftLimits.budgetYearRange.upperBound) 之间"
        )
        case .invalidMonth: ZanzanLocalization.string( "无效的预算月份")
        }
    }
}
