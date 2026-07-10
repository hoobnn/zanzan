import Foundation
import SwiftData

/// 账户写路径命令（设计文档 §4 软删语义 / 5.2）。
struct AccountService {
    let context: ModelContext

    @discardableResult
    func createAccount(_ draft: AccountDraft) throws -> Account {
        let v = try draft.validated()
        let activeCount = try context.fetchCount(
            FetchDescriptor<Account>(predicate: #Predicate { !$0.isSoftDeleted })
        )
        let account = Account(name: v.name, kind: v.kind)
        apply(v, to: account)
        account.sortOrder = activeCount
        context.insert(account)
        try context.save()
        return account
    }

    func updateAccount(uuid: UUID, draft: AccountDraft) throws {
        let v = try draft.validated()
        let account = try fetchActiveAccount(uuid)
        let isInitialBalanceChanged = v.initialBalanceMinorUnits != account.initialBalanceMinorUnits
        // 已有流水（含软删，恢复后口径仍须一致）禁改币种——历史流水币种语义不可漂移
        if v.currencyCode != account.currencyCode {
            // 池内成员卡改币种会破坏「成员币种与池一致」不变量（§5.8），须先解绑
            guard account.creditPoolID == nil else {
                throw AccountServiceError.currencyLockedByCreditPool
            }
            let referenceCount = try context.fetchCount(
                FetchDescriptor<Transaction>(predicate: #Predicate {
                    $0.account?.uuid == uuid || $0.targetAccount?.uuid == uuid
                })
            )
            guard referenceCount == 0 else { throw AccountServiceError.currencyImmutable }
        }
        account.kindRawValue = v.kind.rawValue
        apply(v, to: account)
        account.updatedAt = .now
        if isInitialBalanceChanged {
            // §5.13 失效级联：快照值 = 期初 + 增量，期初变了任意时点的快照都脏，全部失效
            try BalanceSnapshotService.invalidateSnapshots(
                accountUUIDs: [uuid], onOrAfter: .distantPast, context: context
            )
        }
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
            FetchDescriptor<Transaction>(predicate: #Predicate {
                !$0.isSoftDeleted && ($0.account?.uuid == uuid || $0.targetAccount?.uuid == uuid)
            })
        )
        guard referenceCount == 0 else { throw AccountServiceError.hasActiveTransactions }
        account.isSoftDeleted = true
        account.updatedAt = .now
        let snapshots = try context.fetch(
            FetchDescriptor<BalanceSnapshot>(predicate: #Predicate { !$0.isSoftDeleted && $0.accountID == uuid })
        )
        for snapshot in snapshots {
            snapshot.isSoftDeleted = true
            snapshot.updatedAt = .now
        }
        try context.save()
    }

    /// 校准到实际余额（设计文档 5.2）：按与派生余额的差额生成一笔 `adjustment` 收支流水，
    /// 默认不计收支统计；差额为 0 不生成。理财账户市值更新走同一入口。
    /// 外币账户按 §5.4 规则带 `fxRateToBase`：显式入参优先，否则取最近流水快照，两者皆无抛错。
    @discardableResult
    func calibrateBalance(
        accountUUID: UUID,
        actualBalanceMinorUnits: Int,
        occurredAt: Date = .now,
        fxRateToBase: Decimal? = nil
    ) throws -> Transaction? {
        let account = try fetchActiveAccount(accountUUID)
        guard !account.isArchived else { throw AccountServiceError.accountArchived }
        // 先解析汇率再建流水，避免抛错前污染上下文
        var resolvedRate: Decimal? = nil
        if account.currencyCode != FxConversion.baseCurrencyCode {
            let rate = try fxRateToBase ?? FxRateProvider(context: context).rate(for: account.currencyCode)
            guard let rate, rate > 0 else { throw AccountServiceError.missingFxRate }
            resolvedRate = rate
        }
        let currentBalance = try AccountBalanceProvider(context: context).balanceMinorUnits(of: account)
        let delta = actualBalanceMinorUnits - currentBalance
        guard delta != 0 else { return nil }
        let tx = Transaction(
            kind: delta > 0 ? .income : .expense,
            amountMinorUnits: abs(delta),
            occurredAt: occurredAt,
            ledgerID: try fetchDefaultLedgerID()
        )
        tx.account = account
        tx.currencyCode = account.currencyCode
        tx.fxRateToBase = resolvedRate // 本位币恒 nil，外币恒非空（§5.4）
        tx.sourceKindRawValue = TransactionSourceKind.adjustment.rawValue
        tx.isExcludedFromStats = true
        context.insert(tx)
        // §5.13 失效级联：校准流水改变了 occurredAt 起的余额轨迹，该时点起的快照失效
        try BalanceSnapshotService.invalidateSnapshots(
            accountUUIDs: [account.uuid], onOrAfter: occurredAt, context: context
        )
        try context.save()
        return tx
    }

    private func apply(_ v: AccountDraft.Validated, to account: Account) {
        account.name = v.name
        account.subtitle = v.subtitle
        account.currencyCode = v.currencyCode
        account.initialBalanceMinorUnits = v.initialBalanceMinorUnits
        account.creditLimitMinorUnits = v.creditLimitMinorUnits
        account.statementDay = v.statementDay
        account.paymentDueDay = v.paymentDueDay
        account.note = v.note
        account.isIncludedInNetWorth = v.isIncludedInNetWorth
    }

    private func fetchActiveAccount(_ uuid: UUID) throws -> Account {
        let descriptor = FetchDescriptor<Account>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        )
        guard let account = try context.fetch(descriptor).first else {
            throw AccountServiceError.accountNotFound
        }
        return account
    }

    /// 校准流水归属账本：优先默认账本，违例回落首本（§4 同步合并兜底口径）。
    private func fetchDefaultLedgerID() throws -> UUID {
        let ledgers = try context.fetch(
            FetchDescriptor<Ledger>(predicate: #Predicate { !$0.isSoftDeleted })
        )
        guard let ledger = ledgers.first(where: \.isDefault) ?? ledgers.first else {
            throw AccountServiceError.noLedgerAvailable
        }
        return ledger.uuid
    }
}

enum AccountServiceError: LocalizedError {
    case accountNotFound
    case accountArchived
    case hasActiveTransactions
    case noLedgerAvailable
    case currencyImmutable
    case currencyLockedByCreditPool
    case missingFxRate

    var errorDescription: String? {
        switch self {
        case .accountNotFound: String(localized: "账户不存在或已删除")
        case .accountArchived: String(localized: "账户已归档，恢复后才能校准余额")
        case .hasActiveTransactions: String(localized: "账户名下还有流水，无法删除；可先归档或转移流水")
        case .noLedgerAvailable: String(localized: "没有可用账本，无法生成校准流水")
        case .currencyImmutable: String(localized: "账户已有流水，币种不可修改")
        case .currencyLockedByCreditPool: String(localized: "账户在授信池内，需先解绑才能修改币种")
        case .missingFxRate: String(localized: "该币种暂无汇率快照，请提供汇率或先记一笔带汇率的流水")
        }
    }
}
