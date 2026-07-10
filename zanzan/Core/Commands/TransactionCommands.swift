import Foundation
import SwiftData

/// 流水写路径命令（设计文档 5.4）。不变量：ledgerID 非空且活跃、分类方向匹配、
/// kind 终生不可改写、MVP 锁 CNY（fxRateToBase 恒 nil）。
struct TransactionCommands {
    let context: ModelContext

    @discardableResult
    func recordTransaction(_ draft: TransactionDraft, ledgerID: UUID) throws -> StoredTransaction {
        let v = try draft.validated()
        try ensureActiveLedger(ledgerID)
        let tx = StoredTransaction(kind: v.kind, amountMinorUnits: v.amountMinorUnits, occurredAt: v.occurredAt, ledgerID: ledgerID)
        try apply(v, to: tx)
        context.insert(tx)
        try context.save()
        return tx
    }

    func updateTransaction(uuid: UUID, draft: TransactionDraft) throws {
        let tx = try fetchTransaction(uuid, includeDeleted: false)
        guard tx.kind == draft.kind else { throw TransactionCommandError.kindImmutable }
        let v = try draft.validated()
        tx.amountMinorUnits = v.amountMinorUnits
        tx.occurredAt = v.occurredAt
        try apply(v, to: tx)
        tx.updatedAt = .now
        try context.save()
    }

    func softDeleteTransaction(uuid: UUID) throws {
        let tx = try fetchTransaction(uuid, includeDeleted: false)
        tx.isSoftDeleted = true
        tx.updatedAt = .now
        try context.save()
    }

    func undoSoftDeleteTransaction(uuid: UUID) throws {
        let tx = try fetchTransaction(uuid, includeDeleted: true)
        tx.isSoftDeleted = false
        tx.updatedAt = .now
        try context.save()
    }

    // MARK: - 私有

    private func apply(_ v: TransactionDraft.Validated, to tx: StoredTransaction) throws {
        let account = try fetchActiveAccount(v.accountUUID)
        tx.note = v.note
        tx.account = account
        tx.currencyCode = account.currencyCode // MVP 全 CNY；fxRateToBase 恒 nil
        tx.feeMinorUnits = v.feeMinorUnits
        switch v.kind {
        case .expense, .income:
            let category = try fetchActiveCategory(v.categoryUUID!)
            guard category.kind == v.kind else { throw TransactionCommandError.categoryKindMismatch }
            tx.category = category
            tx.targetAccount = nil
        case .transfer:
            tx.targetAccount = try fetchActiveAccount(v.targetAccountUUID!)
            tx.category = nil
        }
    }

    private func ensureActiveLedger(_ uuid: UUID) throws {
        let count = try context.fetchCount(
            FetchDescriptor<StoredLedger>(predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid })
        )
        guard count > 0 else { throw TransactionCommandError.ledgerNotFound }
    }

    private func fetchActiveAccount(_ uuid: UUID) throws -> StoredAccount {
        let descriptor = FetchDescriptor<StoredAccount>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        )
        guard let account = try context.fetch(descriptor).first else {
            throw TransactionCommandError.accountNotFound
        }
        return account
    }

    private func fetchActiveCategory(_ uuid: UUID) throws -> StoredCategory {
        let descriptor = FetchDescriptor<StoredCategory>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        )
        guard let category = try context.fetch(descriptor).first else {
            throw TransactionCommandError.categoryNotFound
        }
        return category
    }

    private func fetchTransaction(_ uuid: UUID, includeDeleted: Bool) throws -> StoredTransaction {
        let predicate: Predicate<StoredTransaction> = includeDeleted
            ? #Predicate { $0.uuid == uuid }
            : #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        guard let tx = try context.fetch(FetchDescriptor<StoredTransaction>(predicate: predicate)).first else {
            throw TransactionCommandError.transactionNotFound
        }
        return tx
    }
}

enum TransactionCommandError: LocalizedError {
    case ledgerNotFound
    case accountNotFound
    case categoryNotFound
    case transactionNotFound
    case categoryKindMismatch
    case kindImmutable

    var errorDescription: String? {
        switch self {
        case .ledgerNotFound: "账本不存在或已删除"
        case .accountNotFound: "账户不存在或已删除"
        case .categoryNotFound: "分类不存在或已删除"
        case .transactionNotFound: "流水不存在"
        case .categoryKindMismatch: "分类方向与流水类型不一致"
        case .kindImmutable: "流水类型不可修改，请删除后重新记一笔"
        }
    }
}
