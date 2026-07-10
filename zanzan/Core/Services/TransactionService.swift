import Foundation
import SwiftData

/// 流水写路径命令（设计文档 5.4）。不变量：ledgerID 非空且活跃、分类方向匹配、
/// kind 终生不可改写；多币种必填规则：外币流水 fxRateToBase 强制非空（缺失预填最近快照）、
/// 本位币恒 nil；跨币种转账 targetAmountMinorUnits 强制非空、同币种强制归 nil。
struct TransactionService {
    let context: ModelContext

    @discardableResult
    func recordTransaction(
        _ draft: TransactionDraft,
        ledgerID: UUID,
        source: (kind: TransactionSourceKind, id: UUID)? = nil
    ) throws -> Transaction {
        let v = try draft.validated()
        try ensureActiveLedger(ledgerID)
        let resolved = try resolve(v, previous: nil)
        let tx = Transaction(kind: v.kind, amountMinorUnits: v.amountMinorUnits, occurredAt: v.occurredAt, ledgerID: ledgerID)
        assign(v, resolved, to: tx)
        // 来源包在首个 save 前写入：崩溃重放的去重承诺（周期按 sourceID 去重、
        // CSV undoBatch 按 sourceID 反查）依赖来源包与流水同一事务落库
        if let source {
            tx.sourceKindRawValue = source.kind.rawValue
            tx.sourceID = source.id
        }
        context.insert(tx)
        try invalidateSnapshots(accounts: [resolved.account.uuid, resolved.targetAccount?.uuid], onOrAfter: v.occurredAt)
        try context.save()
        return tx
    }

    func updateTransaction(uuid: UUID, draft: TransactionDraft) throws {
        let tx = try fetchTransaction(uuid, includeDeleted: false)
        try ensureNotInstallmentManaged(tx)
        try ensureNotSettlement(tx)
        guard tx.kind == draft.kind else { throw TransactionServiceError.kindImmutable }
        let v = try draft.validated()
        // 原单改额守卫（§5.5 编辑金额联动）：有活跃分摊时新金额须 ≥ Σ 活跃分摊，
        // 改小到低于分摊合计会让关联行超额，阻断并要求先调整分摊行
        let reimbursement = ReimbursementService(context: context)
        let allocated = try reimbursement.allocatedAmount(originalID: tx.uuid)
        guard allocated == 0 || v.amountMinorUnits >= allocated else {
            throw TransactionServiceError.amountBelowAllocations
        }
        // 先全量解析校验、再统一赋值——避免抛错前污染上下文（同 calibrateBalance 纪律）
        let resolved = try resolve(v, previous: tx)
        let previousAccounts = [tx.account?.uuid, tx.targetAccount?.uuid]
        let previousOccurredAt = tx.occurredAt
        tx.amountMinorUnits = v.amountMinorUnits
        tx.occurredAt = v.occurredAt
        assign(v, resolved, to: tx)
        tx.updatedAt = .now
        // 金额变化可能改变分摊覆盖情况：按覆盖规则重算原单报销状态（未标记垫付为 no-op）
        try reimbursement.recomputeOriginalStatus(tx)
        try invalidateSnapshots(
            accounts: previousAccounts + [resolved.account.uuid, resolved.targetAccount?.uuid],
            onOrAfter: min(previousOccurredAt, v.occurredAt)
        )
        try context.save()
    }

    func softDeleteTransaction(uuid: UUID) throws {
        let tx = try fetchTransaction(uuid, includeDeleted: false)
        try ensureNotInstallmentManaged(tx)
        try ensureNotSettlement(tx)
        try ensureNoActiveReimbursementLinks(tx)
        tx.isSoftDeleted = true
        tx.updatedAt = .now
        try invalidateSnapshots(accounts: [tx.account?.uuid, tx.targetAccount?.uuid], onOrAfter: tx.occurredAt)
        try context.save()
    }

    func undoSoftDeleteTransaction(uuid: UUID) throws {
        let tx = try fetchTransaction(uuid, includeDeleted: true)
        try ensureNotInstallmentManaged(tx)
        // 到账单恢复须连带恢复其分摊关联行，正确路径是 ReimbursementService.restoreSettlement
        try ensureNotSettlement(tx)
        try ensureReferencesActive(tx)
        tx.isSoftDeleted = false
        tx.updatedAt = .now
        try invalidateSnapshots(accounts: [tx.account?.uuid, tx.targetAccount?.uuid], onOrAfter: tx.occurredAt)
        try context.save()
    }

    /// 期供流水的生命周期与期数表状态强绑定，通用入口删/改/恢复会击穿分期状态机
    /// （期卡死、进度与余额口径分叉），一律阻断，只能经 InstallmentService 操作。
    private func ensureNotInstallmentManaged(_ tx: Transaction) throws {
        guard tx.sourceKind != .installment else {
            throw TransactionServiceError.managedByInstallmentPlan
        }
    }

    /// 到账单金额/字段与分摊关联行强绑定（§5.5），通用入口删/改/恢复一律阻断，
    /// 只能经 ReimbursementService（removeSettlement / restoreSettlement）操作。
    /// 按 rawValue 非空判断：未知高版本 settlementKind 同样阻断（§4 前向兼容）。
    /// 注：ReimbursementService 自身软删/恢复到账单直接改模型、不经本入口，不受此守卫误伤。
    private func ensureNotSettlement(_ tx: Transaction) throws {
        guard tx.settlementKindRawValue.isEmpty else {
            throw TransactionServiceError.managedByReimbursement
        }
    }

    /// 原单有活跃分摊关联时禁止删除（§5.5）：删了原单，关联行与到账单的分摊语义即悬空。
    private func ensureNoActiveReimbursementLinks(_ tx: Transaction) throws {
        let originalID = tx.uuid
        let count = try context.fetchCount(FetchDescriptor<TransactionLink>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.originalTransactionID == originalID }
        ))
        guard count == 0 else { throw TransactionServiceError.hasReimbursementLinks }
    }

    /// 恢复前校验引用均活跃（对称于删除侧阻断）：否则活跃流水挂在已删账户/账本/分类上，
    /// 净资产不算它、月度统计算它，口径分叉。
    private func ensureReferencesActive(_ tx: Transaction) throws {
        // ponytail: ledgerID/account 为 nil 属历史坏数据，不因此卡死恢复，只校验存在的引用
        if let ledgerID = tx.ledgerID {
            do { try ensureActiveLedger(ledgerID) } catch {
                throw TransactionServiceError.restoreReferenceDeleted
            }
        }
        guard tx.account?.isSoftDeleted != true,
              tx.targetAccount?.isSoftDeleted != true,
              tx.category?.isSoftDeleted != true else {
            throw TransactionServiceError.restoreReferenceDeleted
        }
    }

    /// §5.13 快照失效级联：写路径动了哪个账户的哪个时点，该账户该时点起的快照即失效。
    private func invalidateSnapshots(accounts: [UUID?], onOrAfter date: Date) throws {
        try BalanceSnapshotService.invalidateSnapshots(
            accountUUIDs: Set(accounts.compactMap { $0 }), onOrAfter: date, context: context
        )
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
    case managedByReimbursement
    case hasReimbursementLinks
    case amountBelowAllocations
    case restoreReferenceDeleted
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
        case .managedByReimbursement: String(localized: "报销/退款到账单请在报销管理中操作")
        case .hasReimbursementLinks: String(localized: "该流水已有报销/退款到账记录，请先解除关联")
        case .amountBelowAllocations: String(localized: "金额不能低于已报销/退款的分摊合计，请先调整分摊")
        case .restoreReferenceDeleted: String(localized: "流水引用的账本、账户或分类已删除，请先恢复它们")
        case .missingFxRate: String(localized: "外币流水需填写对人民币的汇率")
        case .missingTargetAmount: String(localized: "跨币种转账需填写到账金额")
        }
    }
}
