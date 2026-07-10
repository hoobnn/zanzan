import Foundation
import SwiftData

/// 账户写路径命令（设计文档 §4 软删语义 / 5.2）。
struct AccountCommands {
    let context: ModelContext

    @discardableResult
    func createAccount(_ draft: AccountDraft) throws -> StoredAccount {
        let v = try draft.validated()
        let activeCount = try context.fetchCount(
            FetchDescriptor<StoredAccount>(predicate: #Predicate { !$0.isSoftDeleted })
        )
        let account = StoredAccount(name: v.name, kind: v.kind)
        apply(v, to: account)
        account.sortOrder = activeCount
        context.insert(account)
        try context.save()
        return account
    }

    func updateAccount(uuid: UUID, draft: AccountDraft) throws {
        let v = try draft.validated()
        let account = try fetchActiveAccount(uuid)
        account.kindRawValue = v.kind.rawValue
        apply(v, to: account)
        account.updatedAt = .now
        try context.save()
    }

    func setArchived(uuid: UUID, isArchived: Bool) throws {
        let account = try fetchActiveAccount(uuid)
        account.isArchived = isArchived
        account.updatedAt = .now
        try context.save()
    }

    /// 软删：任何活跃流水引用（收支/转出/转入）都阻断并引导归档；级联软删余额快照。
    func softDeleteAccount(uuid: UUID) throws {
        let account = try fetchActiveAccount(uuid)
        let referenceCount = try context.fetchCount(
            FetchDescriptor<StoredTransaction>(predicate: #Predicate {
                !$0.isSoftDeleted && ($0.account?.uuid == uuid || $0.targetAccount?.uuid == uuid)
            })
        )
        guard referenceCount == 0 else { throw AccountCommandError.hasActiveTransactions }
        account.isSoftDeleted = true
        account.updatedAt = .now
        let snapshots = try context.fetch(
            FetchDescriptor<StoredBalanceSnapshot>(predicate: #Predicate { !$0.isSoftDeleted && $0.accountID == uuid })
        )
        for snapshot in snapshots {
            snapshot.isSoftDeleted = true
            snapshot.updatedAt = .now
        }
        try context.save()
    }

    private func apply(_ v: AccountDraft.Validated, to account: StoredAccount) {
        account.name = v.name
        account.subtitle = v.subtitle
        account.initialBalanceMinorUnits = v.initialBalanceMinorUnits
        account.creditLimitMinorUnits = v.creditLimitMinorUnits
        account.statementDay = v.statementDay
        account.paymentDueDay = v.paymentDueDay
        account.note = v.note
        account.isIncludedInNetWorth = v.isIncludedInNetWorth
    }

    private func fetchActiveAccount(_ uuid: UUID) throws -> StoredAccount {
        let descriptor = FetchDescriptor<StoredAccount>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        )
        guard let account = try context.fetch(descriptor).first else {
            throw AccountCommandError.accountNotFound
        }
        return account
    }
}

enum AccountCommandError: LocalizedError {
    case accountNotFound
    case hasActiveTransactions

    var errorDescription: String? {
        switch self {
        case .accountNotFound: "账户不存在或已删除"
        case .hasActiveTransactions: "账户名下还有流水，无法删除；可先归档或转移流水"
        }
    }
}
