import Foundation
import SwiftData

/// 流水写路径命令（设计文档 5.4）。不变量：ledgerID 非空且活跃、分类方向匹配、
/// kind 终生不可改写、MVP 锁 CNY（fxRateToBase 恒 nil）。
struct TransactionService {
    let context: ModelContext

    @discardableResult
    func recordTransaction(_ draft: TransactionDraft, ledgerID: UUID) throws -> Transaction {
        let v = try draft.validated()
        try ensureActiveLedger(ledgerID)
        let tx = Transaction(kind: v.kind, amountMinorUnits: v.amountMinorUnits, occurredAt: v.occurredAt, ledgerID: ledgerID)
        try apply(v, to: tx)
        context.insert(tx)
        try context.save()
        return tx
    }

    func updateTransaction(uuid: UUID, draft: TransactionDraft) throws {
        let tx = try fetchTransaction(uuid, includeDeleted: false)
        try ensureNotInstallmentManaged(tx)
        guard tx.kind == draft.kind else { throw TransactionServiceError.kindImmutable }
        let v = try draft.validated()
        tx.amountMinorUnits = v.amountMinorUnits
        tx.occurredAt = v.occurredAt
        try apply(v, to: tx)
        tx.updatedAt = .now
        try context.save()
    }

    func softDeleteTransaction(uuid: UUID) throws {
        let tx = try fetchTransaction(uuid, includeDeleted: false)
        try ensureNotInstallmentManaged(tx)
        tx.isSoftDeleted = true
        tx.updatedAt = .now
        try context.save()
    }

    func undoSoftDeleteTransaction(uuid: UUID) throws {
        let tx = try fetchTransaction(uuid, includeDeleted: true)
        try ensureNotInstallmentManaged(tx)
        tx.isSoftDeleted = false
        tx.updatedAt = .now
        try context.save()
    }

    /// 期供流水的生命周期与期数表状态强绑定，通用入口删/改/恢复会击穿分期状态机
    /// （期卡死、进度与余额口径分叉），一律阻断，只能经 InstallmentService 操作。
    private func ensureNotInstallmentManaged(_ tx: Transaction) throws {
        guard tx.sourceKind != .installment else {
            throw TransactionServiceError.managedByInstallmentPlan
        }
    }

    // MARK: - 私有

    private func apply(_ v: TransactionDraft.Validated, to tx: Transaction) throws {
        let account = try fetchActiveAccount(v.accountUUID)
        tx.note = v.note
        tx.account = account
        tx.currencyCode = account.currencyCode // MVP 全 CNY；fxRateToBase 恒 nil
        tx.feeMinorUnits = v.feeMinorUnits
        switch v.kind {
        case .expense, .income:
            let category = try fetchActiveCategory(v.categoryUUID!)
            guard category.kind == v.kind else { throw TransactionServiceError.categoryKindMismatch }
            tx.category = category
            tx.targetAccount = nil
        case .transfer:
            tx.targetAccount = try fetchActiveAccount(v.targetAccountUUID!)
            tx.category = nil
        }
    }

    private func ensureActiveLedger(_ uuid: UUID) throws {
        let count = try context.fetchCount(
            FetchDescriptor<Ledger>(predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid })
        )
        guard count > 0 else { throw TransactionServiceError.ledgerNotFound }
    }

    private func fetchActiveAccount(_ uuid: UUID) throws -> Account {
        let descriptor = FetchDescriptor<Account>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        )
        guard let account = try context.fetch(descriptor).first else {
            throw TransactionServiceError.accountNotFound
        }
        return account
    }

    private func fetchActiveCategory(_ uuid: UUID) throws -> Category {
        let descriptor = FetchDescriptor<Category>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        )
        guard let category = try context.fetch(descriptor).first else {
            throw TransactionServiceError.categoryNotFound
        }
        return category
    }

    private func fetchTransaction(_ uuid: UUID, includeDeleted: Bool) throws -> Transaction {
        let predicate: Predicate<Transaction> = includeDeleted
            ? #Predicate { $0.uuid == uuid }
            : #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        guard let tx = try context.fetch(FetchDescriptor<Transaction>(predicate: predicate)).first else {
            throw TransactionServiceError.transactionNotFound
        }
        return tx
    }
}

enum TransactionServiceError: LocalizedError {
    case ledgerNotFound
    case accountNotFound
    case categoryNotFound
    case transactionNotFound
    case categoryKindMismatch
    case kindImmutable
    case managedByInstallmentPlan

    var errorDescription: String? {
        switch self {
        case .ledgerNotFound: String(localized: "账本不存在或已删除")
        case .accountNotFound: String(localized: "账户不存在或已删除")
        case .categoryNotFound: String(localized: "分类不存在或已删除")
        case .transactionNotFound: String(localized: "流水不存在")
        case .categoryKindMismatch: String(localized: "分类方向与流水类型不一致")
        case .kindImmutable: String(localized: "流水类型不可修改，请删除后重新记一笔")
        case .managedByInstallmentPlan: String(localized: "分期还款流水请在分期计划中操作")
        }
    }
}
