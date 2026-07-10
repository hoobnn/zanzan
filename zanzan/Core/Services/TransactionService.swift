import Foundation
import SwiftData

/// 流水写路径命令（设计文档 5.4）。不变量：ledgerID 非空且活跃、分类方向匹配、
/// kind 终生不可改写；多币种必填规则：外币流水 fxRateToBase 强制非空（缺失预填最近快照）、
/// 本位币恒 nil；跨币种转账 targetAmountMinorUnits 强制非空、同币种强制归 nil。
struct TransactionService {
    let context: ModelContext

    @discardableResult
    func recordTransaction(_ draft: TransactionDraft, ledgerID: UUID) throws -> Transaction {
        let v = try draft.validated()
        try ensureActiveLedger(ledgerID)
        let resolved = try resolve(v, previous: nil)
        let tx = Transaction(kind: v.kind, amountMinorUnits: v.amountMinorUnits, occurredAt: v.occurredAt, ledgerID: ledgerID)
        assign(v, resolved, to: tx)
        context.insert(tx)
        try context.save()
        return tx
    }

    func updateTransaction(uuid: UUID, draft: TransactionDraft) throws {
        let tx = try fetchTransaction(uuid, includeDeleted: false)
        try ensureNotInstallmentManaged(tx)
        guard tx.kind == draft.kind else { throw TransactionServiceError.kindImmutable }
        let v = try draft.validated()
        // 先全量解析校验、再统一赋值——避免抛错前污染上下文（同 calibrateBalance 纪律）
        let resolved = try resolve(v, previous: tx)
        tx.amountMinorUnits = v.amountMinorUnits
        tx.occurredAt = v.occurredAt
        assign(v, resolved, to: tx)
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

    /// 落库前解析产物：全部查库/校验在此完成，赋值阶段不再抛错
    private struct Resolved {
        let account: Account
        let category: Category?
        let targetAccount: Account?
        let fxRateToBase: Decimal?
        let targetAmountMinorUnits: Int?
    }

    private func resolve(_ v: TransactionDraft.Validated, previous: Transaction?) throws -> Resolved {
        let account = try fetchActiveAccount(v.accountUUID)
        var category: Category?
        var targetAccount: Account?
        var targetAmount: Int?
        switch v.kind {
        case .expense, .income:
            let found = try fetchActiveCategory(v.categoryUUID!)
            guard found.kind == v.kind else { throw TransactionServiceError.categoryKindMismatch }
            category = found
        case .transfer:
            let target = try fetchActiveAccount(v.targetAccountUUID!)
            targetAccount = target
            if target.currencyCode == account.currencyCode {
                targetAmount = nil // 同币种转账强制归 nil（§5.4）
            } else if let explicit = v.targetAmountMinorUnits {
                targetAmount = explicit
            } else if let previous,
                      previous.currencyCode == account.currencyCode,
                      previous.targetAccount?.currencyCode == target.currencyCode,
                      let kept = previous.targetAmountMinorUnits {
                targetAmount = kept // 编辑未换币种对：保留原到账金额
            } else {
                // 跨币种转账到账金额强制非空（转入方币种计）
                throw TransactionServiceError.missingTargetAmount
            }
        }
        let fxRate = try resolvedFxRate(
            currencyCode: account.currencyCode, draftRate: v.fxRateToBase, previous: previous
        )
        return Resolved(
            account: account, category: category, targetAccount: targetAccount,
            fxRateToBase: fxRate, targetAmountMinorUnits: targetAmount
        )
    }

    private func assign(_ v: TransactionDraft.Validated, _ r: Resolved, to tx: Transaction) {
        tx.note = v.note
        tx.account = r.account
        tx.currencyCode = r.account.currencyCode // 收支 = 账户币种；转账 = 转出方币种（§5.4）
        tx.fxRateToBase = r.fxRateToBase
        tx.feeMinorUnits = v.feeMinorUnits
        tx.category = r.category
        tx.targetAccount = r.targetAccount
        tx.targetAmountMinorUnits = r.targetAmountMinorUnits
    }

    /// §5.4 汇率必填规则：本位币恒 nil（草稿给了也归 nil）；外币强制非空——
    /// 草稿显式给则用之；编辑未换币种则保留流水既有快照（§4 口径①历史永固，
    /// 禁止被最近快照静默改写）；新记且无快照可预填时抛错。
    private func resolvedFxRate(currencyCode: String, draftRate: Decimal?, previous: Transaction?) throws -> Decimal? {
        guard currencyCode != FxConversion.baseCurrencyCode else { return nil }
        if let draftRate { return draftRate }
        if let previous, previous.currencyCode == currencyCode, let kept = previous.fxRateToBase {
            return kept
        }
        guard let snapshot = try FxRateProvider(context: context).rate(for: currencyCode) else {
            throw TransactionServiceError.missingFxRate
        }
        return snapshot
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
    case missingFxRate
    case missingTargetAmount

    var errorDescription: String? {
        switch self {
        case .ledgerNotFound: String(localized: "账本不存在或已删除")
        case .accountNotFound: String(localized: "账户不存在或已删除")
        case .categoryNotFound: String(localized: "分类不存在或已删除")
        case .transactionNotFound: String(localized: "流水不存在")
        case .categoryKindMismatch: String(localized: "分类方向与流水类型不一致")
        case .kindImmutable: String(localized: "流水类型不可修改，请删除后重新记一笔")
        case .managedByInstallmentPlan: String(localized: "分期还款流水请在分期计划中操作")
        case .missingFxRate: String(localized: "外币流水需填写对人民币的汇率")
        case .missingTargetAmount: String(localized: "跨币种转账需填写到账金额")
        }
    }
}
