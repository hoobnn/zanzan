import Foundation
import SwiftData

/// 账本写路径命令（设计文档 §4 软删语义 / 5.1）。一条命令 = 一个事务，收尾显式 save()。
struct LedgerService {
    let context: ModelContext

    @discardableResult
    func createLedger(_ draft: LedgerDraft) throws -> Ledger {
        let draft = try draft.validated()
        let activeCount = try context.fetchCount(
            FetchDescriptor<Ledger>(predicate: #Predicate { !$0.isSoftDeleted })
        )
        let ledger = Ledger(name: draft.name)
        ledger.colorID = draft.colorID
        ledger.isDefault = activeCount == 0 // 首本即默认（有且仅有一本默认，命令层保证）
        ledger.sortOrder = activeCount
        context.insert(ledger)
        try context.save()
        return ledger
    }

    func updateLedger(uuid: UUID, draft: LedgerDraft) throws {
        let draft = try draft.validated()
        let ledger = try fetchActiveLedger(uuid)
        ledger.name = draft.name
        ledger.colorID = draft.colorID
        ledger.updatedAt = .now
        try context.save()
    }

    func setDefaultLedger(uuid: UUID) throws {
        let target = try fetchActiveLedger(uuid)
        let actives = try context.fetch(
            FetchDescriptor<Ledger>(predicate: #Predicate { !$0.isSoftDeleted })
        )
        for ledger in actives where ledger.isDefault && ledger.uuid != uuid {
            ledger.isDefault = false
            ledger.updatedAt = .now
        }
        target.isDefault = true
        target.updatedAt = .now
        try context.save()
    }

    /// 软删：默认账本禁删；有活跃流水/周期规则/分期计划引用都阻断并引导先处理；
    /// 级联软删该账本预算。
    func softDeleteLedger(uuid: UUID) throws {
        let ledger = try fetchActiveLedger(uuid)
        guard !ledger.isDefault else { throw LedgerServiceError.cannotDeleteDefault }
        let ledgerID: UUID? = uuid
        let activeTransactionCount = try context.fetchCount(
            FetchDescriptor<Transaction>(predicate: #Predicate { !$0.isSoftDeleted && $0.ledgerID == ledgerID })
        )
        guard activeTransactionCount == 0 else { throw LedgerServiceError.hasActiveTransactions }
        // 暂停规则可恢复、完结计划可撤销结清，未软删的一律算活跃引用
        let ruleCount = try context.fetchCount(
            FetchDescriptor<RecurringRule>(predicate: #Predicate {
                !$0.isSoftDeleted && $0.templateLedgerID == ledgerID
            })
        )
        guard ruleCount == 0 else { throw LedgerServiceError.referencedByRecurringRule }
        let planCount = try context.fetchCount(
            FetchDescriptor<InstallmentPlan>(predicate: #Predicate {
                !$0.isSoftDeleted && $0.ledgerID == uuid
            })
        )
        guard planCount == 0 else { throw LedgerServiceError.referencedByInstallmentPlan }
        ledger.isSoftDeleted = true
        ledger.updatedAt = .now
        let budgets = try context.fetch(
            FetchDescriptor<Budget>(predicate: #Predicate { !$0.isSoftDeleted && $0.ledgerID == uuid })
        )
        for budget in budgets {
            budget.isSoftDeleted = true
            budget.updatedAt = .now
        }
        try context.save()
    }

    /// 撤销软删（§4 撤销恢复按相反方向执行）：恢复账本并级联恢复其名下被软删的预算行。
    /// 恢复后不回抢默认位（默认账本禁删，被删时必非默认）。幂等：重复恢复无副作用。
    func undoSoftDeleteLedger(uuid: UUID) throws {
        let ledger = try fetchLedger(uuid, includeDeleted: true)
        ledger.isSoftDeleted = false
        ledger.updatedAt = .now
        let budgets = try context.fetch(
            FetchDescriptor<Budget>(predicate: #Predicate { $0.isSoftDeleted && $0.ledgerID == uuid })
        )
        try BudgetService.restoreSoftDeletedBudgets(budgets, context: context)
        try context.save()
    }

    private func fetchActiveLedger(_ uuid: UUID) throws -> Ledger {
        try fetchLedger(uuid, includeDeleted: false)
    }

    private func fetchLedger(_ uuid: UUID, includeDeleted: Bool) throws -> Ledger {
        let predicate: Predicate<Ledger> = includeDeleted
            ? #Predicate { $0.uuid == uuid }
            : #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        guard let ledger = try context.fetch(FetchDescriptor<Ledger>(predicate: predicate)).first else {
            throw LedgerServiceError.ledgerNotFound
        }
        return ledger
    }
}

enum LedgerServiceError: LocalizedError {
    case ledgerNotFound
    case cannotDeleteDefault
    case hasActiveTransactions
    case referencedByRecurringRule
    case referencedByInstallmentPlan

    var errorDescription: String? {
        switch self {
        case .ledgerNotFound: String(localized: "账本不存在或已删除")
        case .cannotDeleteDefault: String(localized: "默认账本不能删除，请先把其他账本设为默认")
        case .hasActiveTransactions: String(localized: "账本内还有流水，无法删除；可先归档或迁移流水")
        case .referencedByRecurringRule: String(localized: "有周期计划使用该账本，请先调整或删除相关计划")
        case .referencedByInstallmentPlan: String(localized: "有分期/贷款计划使用该账本，请先处理相关计划")
        }
    }
}
