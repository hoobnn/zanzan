import Foundation
import SwiftData

/// 账本写路径命令（设计文档 §4 软删语义 / 5.1）。一条命令 = 一个事务，收尾显式 save()。
struct LedgerCommands {
    let context: ModelContext

    @discardableResult
    func createLedger(_ draft: LedgerDraft) throws -> StoredLedger {
        let draft = try draft.validated()
        let activeCount = try context.fetchCount(
            FetchDescriptor<StoredLedger>(predicate: #Predicate { !$0.isSoftDeleted })
        )
        let ledger = StoredLedger(name: draft.name)
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
            FetchDescriptor<StoredLedger>(predicate: #Predicate { !$0.isSoftDeleted })
        )
        for ledger in actives where ledger.isDefault && ledger.uuid != uuid {
            ledger.isDefault = false
            ledger.updatedAt = .now
        }
        target.isDefault = true
        target.updatedAt = .now
        try context.save()
    }

    /// 软删：默认账本禁删；有活跃流水阻断并引导归档；级联软删该账本预算。
    func softDeleteLedger(uuid: UUID) throws {
        let ledger = try fetchActiveLedger(uuid)
        guard !ledger.isDefault else { throw LedgerCommandError.cannotDeleteDefault }
        let ledgerID: UUID? = uuid
        let activeTransactionCount = try context.fetchCount(
            FetchDescriptor<StoredTransaction>(predicate: #Predicate { !$0.isSoftDeleted && $0.ledgerID == ledgerID })
        )
        guard activeTransactionCount == 0 else { throw LedgerCommandError.hasActiveTransactions }
        ledger.isSoftDeleted = true
        ledger.updatedAt = .now
        let budgets = try context.fetch(
            FetchDescriptor<StoredBudget>(predicate: #Predicate { !$0.isSoftDeleted && $0.ledgerID == uuid })
        )
        for budget in budgets {
            budget.isSoftDeleted = true
            budget.updatedAt = .now
        }
        try context.save()
    }

    private func fetchActiveLedger(_ uuid: UUID) throws -> StoredLedger {
        let descriptor = FetchDescriptor<StoredLedger>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        )
        guard let ledger = try context.fetch(descriptor).first else {
            throw LedgerCommandError.ledgerNotFound
        }
        return ledger
    }
}

enum LedgerCommandError: LocalizedError {
    case ledgerNotFound
    case cannotDeleteDefault
    case hasActiveTransactions

    var errorDescription: String? {
        switch self {
        case .ledgerNotFound: "账本不存在或已删除"
        case .cannotDeleteDefault: "默认账本不能删除，请先把其他账本设为默认"
        case .hasActiveTransactions: "账本内还有流水，无法删除；可先归档或迁移流水"
        }
    }
}
