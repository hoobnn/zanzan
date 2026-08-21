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
        do {
            let tx = try stageTransaction(draft, ledgerID: ledgerID, source: source)
            try context.zanzanSave()
            return tx
        } catch {
            context.rollback()
            throw error
        }
    }

    /// 组合命令专用：完成全部校验、插入与快照失效，但不保存。
    /// 调用方必须在同一同步调用栈内补齐关联状态后统一 `context.zanzanSave()`，
    /// 用于保证“流水 + 业务状态机”只有一个提交边界。
    @discardableResult
    func stageTransaction(
        _ draft: TransactionDraft,
        ledgerID: UUID,
        source: (kind: TransactionSourceKind, id: UUID)? = nil
    ) throws -> Transaction {
        let v = try draft.validated(
            allowZeroAmountForInstallmentCharge: source?.kind == .installment
        )
        let resolved = try resolve(v, ledgerID: ledgerID, previous: nil)
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
        return tx
    }

    func updateTransaction(uuid: UUID, draft: TransactionDraft) throws {
        do {
            _ = try stageUpdateTransaction(uuid: uuid, draft: draft)
            try context.zanzanSave()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// 组合命令专用：完成编辑校验、字段更新、报销状态重算与快照失效，但不保存。
    @discardableResult
    func stageUpdateTransaction(uuid: UUID, draft: TransactionDraft) throws -> Transaction {
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
        guard let ledgerID = tx.ledgerID else {
            throw TransactionServiceError.ledgerNotFound
        }
        let resolved = try resolve(v, ledgerID: ledgerID, previous: tx)
        if resolved.account.currencyCode != tx.currencyCode {
            try ensureNoActiveReimbursementLinks(tx)
        }
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
        return tx
    }

    func softDeleteTransaction(uuid: UUID) throws {
        let tx = try fetchTransaction(uuid, includeDeleted: false)
        try ensureNotInstallmentManaged(tx)
        try ensureNotSettlement(tx)
        try ensureNoActiveReimbursementLinks(tx)
        tx.isSoftDeleted = true
        tx.updatedAt = .now
        try invalidateSnapshots(accounts: [tx.account?.uuid, tx.targetAccount?.uuid], onOrAfter: tx.occurredAt)
        try context.zanzanSave()
    }

    func undoSoftDeleteTransaction(uuid: UUID) throws {
        do {
            let tx = try fetchTransaction(uuid, includeDeleted: true)
            guard tx.isSoftDeleted else { return }
            try ensureTransactionCanBeRestored(tx)
            tx.isSoftDeleted = false
            tx.updatedAt = .now
            try invalidateSnapshots(
                accounts: [tx.account?.uuid, tx.targetAccount?.uuid],
                onOrAfter: tx.occurredAt
            )
            try context.zanzanSave()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// 批量恢复入口复用同一套状态机与引用守卫；只校验，不改模型。
    func ensureTransactionCanBeRestored(
        _ tx: Transaction,
        allowingSoftDeletedImportBatch allowedBatchUUID: UUID? = nil
    ) throws {
        guard tx.sourceKind != nil else {
            throw TransactionServiceError.unsupportedSourceKind
        }
        try ensureNotInstallmentManaged(tx)
        // 到账单恢复须连带恢复其分摊关联行，正确路径是 ReimbursementService.restoreSettlement
        try ensureNotSettlement(tx)
        try ensureImportBatchActiveIfNeeded(tx, allowing: allowedBatchUUID)
        try ensureReferencesActive(tx)
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

    private func ensureImportBatchActiveIfNeeded(
        _ tx: Transaction,
        allowing allowedBatchUUID: UUID?
    ) throws {
        guard tx.sourceKind == .csvImport else { return }
        guard let sourceID = tx.sourceID else {
            throw TransactionServiceError.managedByImportBatch
        }
        if sourceID == allowedBatchUUID { return }
        let count = try context.fetchCount(FetchDescriptor<ImportBatch>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == sourceID }
        ))
        guard count > 0 else { throw TransactionServiceError.managedByImportBatch }
    }

    /// 原单有活跃分摊关联时禁止删除或改币种（§5.5）：否则关联行与到账单的分摊语义会悬空或漂移。
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
        guard let ledgerID = tx.ledgerID, let account = tx.account else {
            throw TransactionServiceError.restoreReferenceDeleted
        }
        do {
            try ensureLedgerUsableForRecord(ledgerID)
            try ensureAccountUsableForRecord(account)
            switch tx.kind {
            case .expense, .income:
                guard let category = tx.category else {
                    throw TransactionServiceError.restoreReferenceDeleted
                }
                try ensureCategoryUsableForRecord(category, ledgerID: ledgerID)
            case .transfer:
                guard let targetAccount = tx.targetAccount else {
                    throw TransactionServiceError.restoreReferenceDeleted
                }
                try ensureAccountUsableForRecord(targetAccount)
            case nil:
                throw TransactionServiceError.restoreReferenceDeleted
            }
        } catch {
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

    private func resolve(
        _ v: TransactionDraft.Validated,
        ledgerID: UUID,
        previous: Transaction?
    ) throws -> Resolved {
        try ensureLedgerUsableForRecord(ledgerID)
        let account = try fetchActiveAccount(v.accountUUID)
        try ensureAccountUsableForRecord(account)
        var category: Category?
        var targetAccount: Account?
        var targetAmount: Int?
        switch v.kind {
        case .expense, .income:
            let found = try fetchActiveCategory(v.categoryUUID!)
            guard found.kind == v.kind else { throw TransactionServiceError.categoryKindMismatch }
            try ensureCategoryUsableForRecord(found, ledgerID: ledgerID)
            category = found
        case .transfer:
            let target = try fetchActiveAccount(v.targetAccountUUID!)
            try ensureAccountUsableForRecord(target)
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
            currencyCode: account.currencyCode,
            draftRate: v.fxRateToBase,
            occurredAt: v.occurredAt,
            previous: previous
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
        tx.locationName = v.locationName
        tx.locationLatitude = v.locationLatitude
        tx.locationLongitude = v.locationLongitude
        tx.isExcludedFromBudget = v.isExcludedFromBudget
        tx.isExcludedFromStats = v.isExcludedFromStats
    }

    /// §5.4 汇率必填规则：本位币恒 nil（草稿给了也归 nil）；外币强制非空——
    /// 草稿显式给则用之；编辑未换币种则保留流水既有快照（§4 口径①历史永固，
    /// 禁止被最近快照静默改写）；新记且无快照可预填时抛错。
    private func resolvedFxRate(
        currencyCode: String,
        draftRate: Decimal?,
        occurredAt: Date,
        previous: Transaction?
    ) throws -> Decimal? {
        guard currencyCode != FxConversion.baseCurrencyCode else { return nil }
        if let draftRate { return draftRate }
        if let previous, previous.currencyCode == currencyCode, let kept = previous.fxRateToBase {
            return kept
        }
        guard let snapshot = try FxRateProvider(context: context)
            .rate(for: currencyCode, asOf: occurredAt) else {
            throw TransactionServiceError.missingFxRate
        }
        return snapshot
    }

    private func ensureLedgerUsableForRecord(_ uuid: UUID) throws {
        let descriptor = FetchDescriptor<Ledger>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        )
        guard let ledger = try context.fetch(descriptor).first else {
            throw TransactionServiceError.ledgerNotFound
        }
        guard !ledger.isArchived else { throw TransactionServiceError.ledgerArchived }
    }

    private func ensureAccountUsableForRecord(_ account: Account) throws {
        guard !account.isSoftDeleted else { throw TransactionServiceError.accountNotFound }
        guard !account.isArchived else { throw TransactionServiceError.accountArchived }
        guard account.isSelectableForRecord else {
            throw TransactionServiceError.accountNotSelectable
        }
    }

    /// 子分类自身可用仍不够；任一祖先归档都会让整条分类路径不可选。
    private func ensureCategoryUsableForRecord(_ category: Category, ledgerID: UUID) throws {
        guard category.ledgerID == nil || category.ledgerID == ledgerID else {
            throw TransactionServiceError.categoryLedgerMismatch
        }
        var current: Category? = category
        var visited: Set<UUID> = []
        while let node = current {
            guard !node.isSoftDeleted else {
                throw TransactionServiceError.categoryNotFound
            }
            guard visited.insert(node.uuid).inserted else {
                throw TransactionServiceError.categoryNotFound
            }
            guard !node.isArchived else {
                throw TransactionServiceError.categoryArchived
            }
            guard node.ledgerID == nil || node.ledgerID == ledgerID else {
                throw TransactionServiceError.categoryLedgerMismatch
            }
            guard let parentID = node.parentID else { return }
            current = try fetchActiveCategory(parentID)
        }
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
    case ledgerArchived
    case accountNotFound
    case accountArchived
    case accountNotSelectable
    case categoryNotFound
    case categoryArchived
    case transactionNotFound
    case categoryKindMismatch
    case categoryLedgerMismatch
    case kindImmutable
    case managedByInstallmentPlan
    case managedByReimbursement
    case managedByImportBatch
    case unsupportedSourceKind
    case hasReimbursementLinks
    case amountBelowAllocations
    case restoreReferenceDeleted
    case missingFxRate
    case missingTargetAmount

    var errorDescription: String? {
        switch self {
        case .ledgerNotFound: ZanzanLocalization.string( "账本不存在或已删除")
        case .ledgerArchived: ZanzanLocalization.string( "账本已归档，请先取消归档再使用")
        case .accountNotFound: ZanzanLocalization.string( "账户不存在或已删除")
        case .accountArchived: ZanzanLocalization.string( "账户已归档，请先取消归档再使用")
        case .accountNotSelectable: ZanzanLocalization.string( "账户当前不可用于记账，请在账户设置中启用后再使用")
        case .categoryNotFound: ZanzanLocalization.string( "分类不存在或已删除")
        case .categoryArchived: ZanzanLocalization.string( "分类已归档，请先取消归档再使用")
        case .transactionNotFound: ZanzanLocalization.string( "流水不存在")
        case .categoryKindMismatch: ZanzanLocalization.string( "分类方向与流水类型不一致")
        case .categoryLedgerMismatch: ZanzanLocalization.string( "只能使用全局分类或本账本的分类")
        case .kindImmutable: ZanzanLocalization.string( "流水类型不可修改，请删除后重新记一笔")
        case .managedByInstallmentPlan: ZanzanLocalization.string( "分期还款流水请在分期计划中操作")
        case .managedByReimbursement: ZanzanLocalization.string( "报销/退款到账单请在报销管理中操作")
        case .managedByImportBatch: ZanzanLocalization.string( "该流水属于已撤销的导入批次，请先恢复批次")
        case .unsupportedSourceKind:
            ZanzanLocalization.string( "该流水由更高版本创建，请升级 App 后恢复")
        case .hasReimbursementLinks: ZanzanLocalization.string( "该流水已有报销/退款到账记录，请先解除关联")
        case .amountBelowAllocations: ZanzanLocalization.string( "金额不能低于已报销/退款的分摊合计，请先调整分摊")
        case .restoreReferenceDeleted: ZanzanLocalization.string( "流水引用的账本、账户或分类已删除，请先恢复它们")
        case .missingFxRate: ZanzanLocalization.string( "外币流水需填写对人民币的汇率")
        case .missingTargetAmount: ZanzanLocalization.string( "跨币种转账需填写到账金额")
        }
    }
}
