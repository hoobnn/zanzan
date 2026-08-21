import Foundation
import SwiftData

/// 报销/退款写路径命令（设计文档 5.4 报销流程 / 5.5 命令层不变量）。
/// 原单 kind 终生保持 expense；到账单是独立 income（settlementKind 冗余标记），
/// 经 TransactionLink 一行一次分摊建 M:N 关联；waiting → settled 由分摊覆盖驱动，
/// 解除关联自动回退。不变量：单张原单 Σ 分摊 ≤ 原单金额；单笔到账单 Σ 分摊 ≤ 到账金额。
struct ReimbursementService {
    /// 一次分摊：到账单对某张原单的分摊金额（分，**以原单币种计**——
    /// §5.5 TransactionLink.amountMinorUnits 口径，报销进度只对原单有意义）。
    struct Allocation {
        let originalTransactionUUID: UUID
        let amountMinorUnits: Int

        init(originalTransactionUUID: UUID, amountMinorUnits: Int) {
            self.originalTransactionUUID = originalTransactionUUID
            self.amountMinorUnits = amountMinorUnits
        }
    }

    let context: ModelContext

    // MARK: - 垫付标记

    /// 把既有支出流水标记为垫付（待报销），进入 waiting 状态。
    /// 前向兼容（R3-L1）：只有空串（未标记）可写入，高版本未知状态串不被覆写
    func markAwaitingReimbursement(transactionUUID: UUID) throws {
        do {
            let tx = try fetchActiveTransaction(transactionUUID)
            try stageMarkAwaitingReimbursement(on: tx)
            try context.zanzanSave()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// 取消垫付标记；已有分摊关联时阻断（须先解除关联）
    func unmarkReimbursement(transactionUUID: UUID) throws {
        do {
            let tx = try fetchActiveTransaction(transactionUUID)
            try stageUnmarkReimbursement(on: tx)
            try context.zanzanSave()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// 组合命令专用：把垫付标记同步到目标状态，但不保存。
    /// settled 状态仍由到账关联状态机管理；未知高版本状态在未请求改动时原样保留。
    func stageReimbursementSelection(_ isMarked: Bool, on transaction: Transaction) throws {
        guard !transaction.isSoftDeleted else {
            throw ReimbursementServiceError.transactionNotFound
        }
        if transaction.reimbursementStatusRawValue.isEmpty {
            if isMarked {
                try stageMarkAwaitingReimbursement(on: transaction)
            }
            return
        }
        guard let status = transaction.reimbursementStatus else {
            if isMarked {
                throw ReimbursementServiceError.unsupportedReimbursementStatus
            }
            return
        }
        switch (status, isMarked) {
        case (.waiting, false):
            try stageUnmarkReimbursement(on: transaction)
        case (.settled, false):
            throw ReimbursementServiceError.notWaiting
        default:
            break
        }
    }

    /// 实报少于垫付时手动结案置 settled（5.5）
    func settleManually(transactionUUID: UUID) throws {
        let tx = try fetchActiveTransaction(transactionUUID)
        guard tx.reimbursementStatus == .waiting else { throw ReimbursementServiceError.notWaiting }
        tx.reimbursementStatusRawValue = ReimbursementStatus.settled.rawValue
        tx.updatedAt = .now
        try context.zanzanSave()
    }

    // MARK: - 登记到账

    /// 登记报销打款/退款入账：新建 income 到账单，对每张原单各建一条分摊关联，
    /// 校验两侧 Σ 分摊上限后按覆盖情况推进原单状态。报销要求原单已标记垫付；退款不要求。
    @discardableResult
    func recordSettlement(
        kind: TransactionLinkKind,
        amountMinorUnits: Int,
        occurredAt: Date,
        accountUUID: UUID,
        ledgerID: UUID,
        note: String = "",
        allocations: [Allocation]
    ) throws -> Transaction {
        guard amountMinorUnits > 0,
              amountMinorUnits <= MoneyAmount.maxAbsoluteMinorUnits else {
            throw ReimbursementServiceError.invalidSettlementAmount
        }
        guard DraftLimits.occurredAtRange.contains(occurredAt) else {
            throw ReimbursementServiceError.occurredAtOutOfRange
        }
        let normalizedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedNote.count <= DraftLimits.maxNoteLength else {
            throw ReimbursementServiceError.noteTooLong
        }
        guard !allocations.isEmpty,
              allocations.allSatisfy({
                  $0.amountMinorUnits > 0
                      && $0.amountMinorUnits <= MoneyAmount.maxAbsoluteMinorUnits
              }) else {
            throw ReimbursementServiceError.invalidAllocation
        }
        let originalIDs = allocations.map(\.originalTransactionUUID)
        guard Set(originalIDs).count == originalIDs.count else {
            throw ReimbursementServiceError.invalidAllocation
        }
        try ensureActiveLedger(ledgerID)
        let account = try fetchActiveAccount(accountUUID)

        // 到账单汇率（§5.4）：到账账户非 CNY 时 fxRateToBase 必填——经 FxRateProvider
        // 最近快照预填，无快照阻断；CNY 恒 nil
        let settlementCurrency = account.currencyCode
        var settlementFxRate: Decimal?
        if settlementCurrency != FxConversion.baseCurrencyCode {
            guard let rate = try FxRateProvider(context: context)
                .rate(for: settlementCurrency, asOf: occurredAt),
                  rate > 0 else {
                throw ReimbursementServiceError.missingSettlementFxRate
            }
            settlementFxRate = rate
        }

        // 校验各原单：支出单、报销须已标记垫付、累计分摊不超原单金额
        // （「单张原单 Σ 分摊 ≤ 原单金额」始终在原单币种内精确比较，不受跨币种影响，§5.5）
        var originals: [Transaction] = []
        for allocation in allocations {
            let original = try fetchActiveTransaction(allocation.originalTransactionUUID)
            guard original.kind == .expense else { throw ReimbursementServiceError.originalNotExpense }
            // 跨账本关联阻断（R4-L2）：退款冲减按账本统计，原单与到账单必须同账本
            guard original.ledgerID == ledgerID else {
                throw ReimbursementServiceError.crossLedgerAllocation
            }
            if kind == .reimbursement {
                guard original.reimbursementStatus != nil else {
                    throw ReimbursementServiceError.originalNotMarked
                }
            }
            let allocated = try allocatedAmount(originalID: original.uuid)
            guard try MoneyArithmetic.add(allocated, allocation.amountMinorUnits)
                <= original.amountMinorUnits else {
                throw ReimbursementServiceError.allocationExceedsOriginal
            }
            originals.append(original)
        }

        try validateSettlementAllocationTotal(
            kind: kind,
            amountMinorUnits: amountMinorUnits,
            currencyCode: settlementCurrency,
            fxRateToBase: settlementFxRate,
            originals: originals,
            allocationAmounts: allocations.map(\.amountMinorUnits)
        )

        // 到账单：income，不挂分类（统计口径由投影器剔除/冲减，见 Transaction+StatsAmounts）
        let settlement = Transaction(
            kind: .income, amountMinorUnits: amountMinorUnits, occurredAt: occurredAt, ledgerID: ledgerID
        )
        settlement.account = account
        settlement.currencyCode = settlementCurrency // 收支币种 = 账户币种（§5.4）
        settlement.fxRateToBase = settlementFxRate // 非 CNY 必填（上方已校验），CNY 恒 nil
        settlement.note = normalizedNote
        settlement.settlementKindRawValue = kind.rawValue
        context.insert(settlement)

        for (original, allocation) in zip(originals, allocations) {
            context.insert(TransactionLink(
                originalTransactionID: original.uuid,
                settlementTransactionID: settlement.uuid,
                kind: kind,
                amountMinorUnits: allocation.amountMinorUnits
            ))
        }
        for original in originals {
            try upgradeOriginalStatusIfCovered(original)
        }
        try invalidateSnapshots(for: settlement)
        try context.zanzanSave()
        return settlement
    }

    // MARK: - 解除关联

    /// 软删到账单：级联软删其全部分摊关联，回退受影响原单状态（5.5）
    func removeSettlement(transactionUUID: UUID) throws {
        let settlement = try fetchActiveTransaction(transactionUUID)
        guard settlement.settlementKind != nil else { throw ReimbursementServiceError.notSettlement }
        let links = try activeLinks(settlementID: settlement.uuid)
        let deletedAt = Date.now
        for link in links {
            link.isSoftDeleted = true
            link.updatedAt = deletedAt
        }
        settlement.isSoftDeleted = true
        settlement.updatedAt = deletedAt
        for link in links {
            if let original = try? fetchActiveTransaction(link.originalTransactionID) {
                try recomputeOriginalStatus(original)
            }
        }
        try invalidateSnapshots(for: settlement)
        try context.zanzanSave()
    }

    /// 恢复被 removeSettlement 软删的到账单（§4 撤销恢复按相反方向执行）：
    /// 恢复到账单流水与其被级联软删的关联行，重算受影响原单状态与到账单 settlementKind 标记。
    /// 软删期间若已另记到账导致恢复后原单超额分摊，先行阻断（不落任何改动）。
    func restoreSettlement(transactionUUID: UUID) throws {
        do {
            let settlement = try fetchSoftDeletedTransaction(transactionUUID)
            guard settlement.settlementKind != nil else { throw ReimbursementServiceError.notSettlement }
            guard let ledgerID = settlement.ledgerID else {
                throw ReimbursementServiceError.ledgerNotFound
            }
            try ensureActiveLedger(ledgerID)
            guard let accountID = settlement.account?.uuid else {
                throw ReimbursementServiceError.accountNotFound
            }
            _ = try fetchActiveAccount(accountID)
            // 删除到账时所有级联 link 与到账单写入同一 updatedAt；只恢复这一批，
            // 早先被用户单独删除的 link 保持删除，撤销才是删除命令的精确反向。
            let links = try softDeletedLinks(
                settlementID: settlement.uuid, deletedAt: settlement.updatedAt
            )

            // 先校验后落改：恢复不得使任一原单超额分摊（§5.5 Σ 分摊 ≤ 原单金额）
            var restoredByOriginal: [UUID: Int] = [:]
            for link in links {
                restoredByOriginal[link.originalTransactionID] = try MoneyArithmetic.add(
                    restoredByOriginal[link.originalTransactionID, default: 0],
                    link.amountMinorUnits
                )
            }
            var originalsByID: [UUID: Transaction] = [:]
            for (originalID, restored) in restoredByOriginal {
                let original = try fetchActiveTransaction(originalID)
                let allocated = try allocatedAmount(originalID: originalID)
                guard try MoneyArithmetic.add(allocated, restored) <= original.amountMinorUnits else {
                    throw ReimbursementServiceError.allocationExceedsOriginal
                }
                originalsByID[originalID] = original
            }
            if settlement.settlementKind == .refund {
                let restoredOriginals = try links.map { link in
                    guard let original = originalsByID[link.originalTransactionID] else {
                        throw ReimbursementServiceError.transactionNotFound
                    }
                    return original
                }
                try validateSettlementAllocationTotal(
                    kind: .refund,
                    amountMinorUnits: settlement.amountMinorUnits,
                    currencyCode: settlement.currencyCode,
                    fxRateToBase: settlement.fxRateToBase,
                    originals: restoredOriginals,
                    allocationAmounts: links.map(\.amountMinorUnits)
                )
            }

            for link in links {
                link.isSoftDeleted = false
                link.updatedAt = .now
            }
            settlement.isSoftDeleted = false
            settlement.updatedAt = .now
            if let kind = links.first?.kind {
                settlement.settlementKindRawValue = kind.rawValue // 冗余标记按关联行重算（5.4）
            }
            for original in originalsByID.values {
                try upgradeOriginalStatusIfCovered(original)
            }
            try invalidateSnapshots(for: settlement)
            try context.zanzanSave()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// 软删单条分摊关联：原单状态回退；到账单关联清零时重算冗余标记（回落为普通收入）
    func removeLink(linkUUID: UUID) throws {
        let descriptor = FetchDescriptor<TransactionLink>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == linkUUID }
        )
        guard let link = try context.fetch(descriptor).first else {
            throw ReimbursementServiceError.linkNotFound
        }
        let settlement = try? fetchActiveTransaction(link.settlementTransactionID)
        if let settlement, settlement.settlementKind == .refund {
            let remainingLinks = try activeLinks(settlementID: link.settlementTransactionID)
                .filter { $0.uuid != link.uuid }
            if !remainingLinks.isEmpty {
                try validateSettlementAllocationTotal(
                    kind: .refund,
                    amountMinorUnits: settlement.amountMinorUnits,
                    currencyCode: settlement.currencyCode,
                    fxRateToBase: settlement.fxRateToBase,
                    originals: try remainingLinks.map {
                        try fetchActiveTransaction($0.originalTransactionID)
                    },
                    allocationAmounts: remainingLinks.map(\.amountMinorUnits)
                )
            }
        }
        link.isSoftDeleted = true
        link.updatedAt = .now
        if let original = try? fetchActiveTransaction(link.originalTransactionID) {
            try recomputeOriginalStatus(original)
        }
        if let settlement, try activeLinks(settlementID: settlement.uuid).isEmpty {
            settlement.settlementKindRawValue = "" // 冗余标记可由关联表全量重算（5.4）
            settlement.updatedAt = .now
        }
        try context.zanzanSave()
    }

    /// 恢复单条分摊关联：到账单在最后一条关联被移除后可能已回落为普通收入，
    /// 因此恢复前重新校验关联两端、分摊上限与到账单形态，不能只翻软删标记。
    func restoreLink(linkUUID: UUID) throws {
        do {
            let descriptor = FetchDescriptor<TransactionLink>(
                predicate: #Predicate { $0.uuid == linkUUID }
            )
            guard let link = try context.fetch(descriptor).first else {
                throw ReimbursementServiceError.linkNotFound
            }
            guard link.isSoftDeleted else { return }
            guard let kind = link.kind else {
                throw ReimbursementServiceError.unsupportedSettlementKind
            }
            guard link.amountMinorUnits > 0,
                  link.amountMinorUnits <= MoneyAmount.maxAbsoluteMinorUnits else {
                throw ReimbursementServiceError.invalidAllocation
            }

            let original = try fetchActiveTransaction(link.originalTransactionID)
            let settlement = try fetchActiveTransaction(link.settlementTransactionID)
            guard original.kind == .expense,
                  settlement.kind == .income,
                  let ledgerID = settlement.ledgerID,
                  original.ledgerID == ledgerID,
                  settlement.category == nil else {
                throw ReimbursementServiceError.invalidSettlementLink
            }
            try ensureActiveLedger(ledgerID)
            guard let accountID = settlement.account?.uuid else {
                throw ReimbursementServiceError.accountNotFound
            }
            _ = try fetchActiveAccount(accountID)
            guard settlement.amountMinorUnits > 0,
                  settlement.amountMinorUnits <= MoneyAmount.maxAbsoluteMinorUnits else {
                throw ReimbursementServiceError.invalidSettlementAmount
            }
            if !settlement.settlementKindRawValue.isEmpty {
                guard let settlementKind = settlement.settlementKind else {
                    throw ReimbursementServiceError.unsupportedSettlementKind
                }
                guard settlementKind == kind else {
                    throw ReimbursementServiceError.invalidSettlementLink
                }
            }
            try ensureOriginalSupports(kind: kind, original: original)

            let existingLinks = try activeLinks(settlementID: settlement.uuid)
            var originalIDs: Set<UUID> = []
            var originals: [Transaction] = []
            for existing in existingLinks {
                guard let existingKind = existing.kind else {
                    throw ReimbursementServiceError.unsupportedSettlementKind
                }
                guard existingKind == kind,
                      existing.amountMinorUnits > 0,
                      existing.amountMinorUnits <= MoneyAmount.maxAbsoluteMinorUnits,
                      originalIDs.insert(existing.originalTransactionID).inserted,
                      existing.originalTransactionID != original.uuid else {
                    throw ReimbursementServiceError.invalidSettlementLink
                }
                let existingOriginal = try fetchActiveTransaction(existing.originalTransactionID)
                guard existingOriginal.kind == .expense,
                      existingOriginal.ledgerID == ledgerID else {
                    throw ReimbursementServiceError.invalidSettlementLink
                }
                try ensureOriginalSupports(kind: kind, original: existingOriginal)
                originals.append(existingOriginal)
            }

            let allocated = try allocatedAmount(originalID: original.uuid)
            guard try MoneyArithmetic.add(allocated, link.amountMinorUnits)
                <= original.amountMinorUnits else {
                throw ReimbursementServiceError.allocationExceedsOriginal
            }
            try validateSettlementAllocationTotal(
                kind: kind,
                amountMinorUnits: settlement.amountMinorUnits,
                currencyCode: settlement.currencyCode,
                fxRateToBase: settlement.fxRateToBase,
                originals: originals + [original],
                allocationAmounts: existingLinks.map(\.amountMinorUnits) + [link.amountMinorUnits]
            )

            link.isSoftDeleted = false
            link.updatedAt = .now
            settlement.settlementKindRawValue = kind.rawValue
            settlement.updatedAt = .now
            try upgradeOriginalStatusIfCovered(original)
            try context.zanzanSave()
        } catch {
            context.rollback()
            throw error
        }
    }

    // MARK: - 数据维护

    /// 由活跃关联行全量重建到账单的冗余身份标记。关联行是唯一真相；
    /// 损坏、混合或未知高版本数据一律阻断，不猜测、不覆写。
    @discardableResult
    func rebuildSettlementKinds() throws -> Int {
        do {
            let transactions = try context.fetch(
                FetchDescriptor<Transaction>(predicate: #Predicate { !$0.isSoftDeleted })
            )
            var transactionsByID: [UUID: Transaction] = [:]
            for transaction in transactions {
                guard transactionsByID.updateValue(transaction, forKey: transaction.uuid) == nil else {
                    throw ReimbursementServiceError.invalidSettlementLink
                }
            }

            let links = try context.fetch(
                FetchDescriptor<TransactionLink>(predicate: #Predicate { !$0.isSoftDeleted })
            )
            var kindsBySettlementID: [UUID: TransactionLinkKind] = [:]
            for link in links {
                guard let kind = link.kind else {
                    throw ReimbursementServiceError.unsupportedSettlementKind
                }
                guard
                    let original = transactionsByID[link.originalTransactionID],
                    let settlement = transactionsByID[link.settlementTransactionID],
                    original.kind == .expense,
                    settlement.kind == .income,
                    original.ledgerID == settlement.ledgerID,
                    link.amountMinorUnits > 0
                else {
                    throw ReimbursementServiceError.invalidSettlementLink
                }
                if let existing = kindsBySettlementID[settlement.uuid], existing != kind {
                    throw ReimbursementServiceError.invalidSettlementLink
                }
                kindsBySettlementID[settlement.uuid] = kind
            }

            let changedAt = Date.now
            var changedCount = 0
            for transaction in transactions {
                guard transaction.settlementKindRawValue.isEmpty
                        || transaction.settlementKind != nil else {
                    throw ReimbursementServiceError.unsupportedSettlementKind
                }
                let expected = kindsBySettlementID[transaction.uuid]?.rawValue ?? ""
                guard transaction.settlementKindRawValue != expected else { continue }
                transaction.settlementKindRawValue = expected
                transaction.updatedAt = changedAt
                changedCount += 1
            }
            try context.zanzanSave()
            return changedCount
        } catch {
            context.rollback()
            throw error
        }
    }

    // MARK: - 私有

    private func stageMarkAwaitingReimbursement(on transaction: Transaction) throws {
        guard transaction.kind == .expense else {
            throw ReimbursementServiceError.originalNotExpense
        }
        guard transaction.reimbursementStatusRawValue.isEmpty else {
            throw transaction.reimbursementStatus != nil
                ? ReimbursementServiceError.alreadyMarked
                : ReimbursementServiceError.unsupportedReimbursementStatus
        }
        transaction.reimbursementStatusRawValue = ReimbursementStatus.waiting.rawValue
        transaction.updatedAt = .now
    }

    private func stageUnmarkReimbursement(on transaction: Transaction) throws {
        guard transaction.reimbursementStatus != nil else {
            throw ReimbursementServiceError.notMarked
        }
        guard try allocatedAmount(originalID: transaction.uuid) == 0 else {
            throw ReimbursementServiceError.hasAllocations
        }
        transaction.reimbursementStatusRawValue = ""
        transaction.updatedAt = .now
    }

    /// 到账单创建、软删、恢复都会改变账户余额轨迹；同一提交边界内失效该时点及之后的缓存。
    /// 虽然当前到账单只有来源账户，仍同时收集 targetAccount，防历史/同步数据带转入引用时漏失效。
    private func invalidateSnapshots(for transaction: Transaction) throws {
        let accountUUIDs = Set(
            [transaction.account?.uuid, transaction.targetAccount?.uuid].compactMap { $0 }
        )
        guard !accountUUIDs.isEmpty else { return }
        try BalanceSnapshotService.invalidateSnapshots(
            accountUUIDs: accountUUIDs,
            onOrAfter: transaction.occurredAt,
            context: context
        )
    }

    private func ensureOriginalSupports(
        kind: TransactionLinkKind,
        original: Transaction
    ) throws {
        guard kind == .reimbursement else { return }
        guard original.reimbursementStatus != nil else {
            throw original.reimbursementStatusRawValue.isEmpty
                ? ReimbursementServiceError.originalNotMarked
                : ReimbursementServiceError.unsupportedReimbursementStatus
        }
    }

    /// 「Σ 分摊 ≤ 到账金额」（§5.5）：同币种精确比较，跨币种按各自快照折本位币并复用 1% 容差。
    /// 退款额外要求全额分摊；报销仍允许 Σ < 到账。
    private func validateSettlementAllocationTotal(
        kind: TransactionLinkKind,
        amountMinorUnits: Int,
        currencyCode: String,
        fxRateToBase: Decimal?,
        originals: [Transaction],
        allocationAmounts: [Int]
    ) throws {
        guard originals.count == allocationAmounts.count else {
            throw ReimbursementServiceError.invalidAllocation
        }
        let allocationTotal = try MoneyArithmetic.sum(allocationAmounts)
        if originals.allSatisfy({ $0.currencyCode == currencyCode }) {
            guard allocationTotal <= amountMinorUnits else {
                throw ReimbursementServiceError.allocationExceedsSettlement
            }
            if kind == .refund, allocationTotal != amountMinorUnits {
                throw ReimbursementServiceError.refundAllocationMismatch
            }
            return
        }

        let convertedAllocationTotal = try MoneyArithmetic.sum(
            zip(originals, allocationAmounts).map { pair in
                try FxConversion.checkedToBaseMinorUnits(pair.1, rate: baseRate(of: pair.0))
            }
        )
        let convertedSettlement = try FxConversion.checkedToBaseMinorUnits(
            amountMinorUnits, rate: fxRateToBase ?? 1
        )
        let upperBound = Decimal(convertedSettlement) * (1 + FxConversion.reimbursementToleranceRatio)
        guard Decimal(convertedAllocationTotal) <= upperBound else {
            throw ReimbursementServiceError.allocationExceedsSettlement
        }
        if kind == .refund {
            let lowerBound = Decimal(convertedSettlement)
                * (1 - FxConversion.reimbursementToleranceRatio)
            guard Decimal(convertedAllocationTotal) >= lowerBound else {
                throw ReimbursementServiceError.refundAllocationMismatch
            }
        }
    }

    /// 流水折本位币所用汇率：CNY 恒 1；外币取记账时快照，快照缺失（历史坏数据，
    /// §5.4 本应由命令层强制非空）按 1:1 兜底——口径同 FxRateProvider「无快照按 1:1 折算」约定
    private func baseRate(of tx: Transaction) -> Decimal {
        guard tx.currencyCode != FxConversion.baseCurrencyCode else { return 1 }
        return tx.fxRateToBase ?? 1
    }

    /// 状态重算按方向拆两个入口（schema 冻结、无「手动结案」标记位，用方向语义保住
    /// settleManually 的决定）：
    ///
    /// 新增分摊方向（recordSettlement / restoreSettlement）：只升级。waiting 且覆盖满额
    /// → settled；绝不把 settled 降回 waiting——settled 只可能来自满额覆盖或手动结案，
    /// 新增分摊只会增加覆盖，两种来源都不应被静默推翻。
    private func upgradeOriginalStatusIfCovered(_ original: Transaction) throws {
        guard original.reimbursementStatus == .waiting else { return }
        let allocated = try allocatedAmount(originalID: original.uuid)
        guard allocated >= original.amountMinorUnits else { return }
        original.reimbursementStatusRawValue = ReimbursementStatus.settled.rawValue
        original.updatedAt = .now
    }

    /// 移除分摊方向（removeSettlement / removeLink）：按覆盖全量重算，满额 → settled、
    /// 不足 → waiting——settled→waiting 的降级只允许出现在本入口（§4 解除关联回退明文）。
    /// internal：TransactionService.updateTransaction 编辑原单后也走本入口——金额改大属
    /// 「覆盖分母变化」，settled 且不满额时降级视同移除方向（用户主动改单、非静默推翻；
    /// 代价是手动结案的原单被编辑后会回到 waiting，schema 无手动结案标记位，接受）。
    func recomputeOriginalStatus(_ original: Transaction) throws {
        guard original.reimbursementStatus != nil else { return }
        let allocated = try allocatedAmount(originalID: original.uuid)
        let status: ReimbursementStatus = allocated >= original.amountMinorUnits ? .settled : .waiting
        original.reimbursementStatusRawValue = status.rawValue
        original.updatedAt = .now
    }

    /// 原单已报销/已退款额 = Σ 其活跃关联行金额（派生值不落库，5.5）。
    /// internal：TransactionService 的原单改额守卫复用同一口径。
    func allocatedAmount(originalID: UUID) throws -> Int {
        let links = try context.fetch(FetchDescriptor<TransactionLink>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.originalTransactionID == originalID }
        ))
        return try MoneyArithmetic.sum(links.map(\.amountMinorUnits))
    }

    private func activeLinks(settlementID: UUID) throws -> [TransactionLink] {
        try context.fetch(FetchDescriptor<TransactionLink>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.settlementTransactionID == settlementID }
        ))
    }

    private func softDeletedLinks(
        settlementID: UUID, deletedAt: Date
    ) throws -> [TransactionLink] {
        try context.fetch(FetchDescriptor<TransactionLink>(
            predicate: #Predicate {
                $0.isSoftDeleted && $0.settlementTransactionID == settlementID
                    && $0.updatedAt == deletedAt
            }
        ))
    }

    private func fetchSoftDeletedTransaction(_ uuid: UUID) throws -> Transaction {
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.isSoftDeleted && $0.uuid == uuid }
        )
        guard let tx = try context.fetch(descriptor).first else {
            throw ReimbursementServiceError.transactionNotFound
        }
        return tx
    }

    private func fetchActiveTransaction(_ uuid: UUID) throws -> Transaction {
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        )
        guard let tx = try context.fetch(descriptor).first else {
            throw ReimbursementServiceError.transactionNotFound
        }
        return tx
    }

    private func fetchActiveAccount(_ uuid: UUID) throws -> Account {
        let descriptor = FetchDescriptor<Account>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        )
        guard let account = try context.fetch(descriptor).first else {
            throw ReimbursementServiceError.accountNotFound
        }
        guard !account.isArchived, account.isSelectableForRecord else {
            throw ReimbursementServiceError.accountNotRecordable
        }
        return account
    }

    private func ensureActiveLedger(_ uuid: UUID) throws {
        let descriptor = FetchDescriptor<Ledger>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        )
        guard let ledger = try context.fetch(descriptor).first else {
            throw ReimbursementServiceError.ledgerNotFound
        }
        guard !ledger.isArchived else { throw ReimbursementServiceError.ledgerArchived }
    }
}

enum ReimbursementServiceError: LocalizedError, Equatable {
    case transactionNotFound
    case accountNotFound
    case accountNotRecordable
    case ledgerNotFound
    case ledgerArchived
    case linkNotFound
    case originalNotExpense
    case alreadyMarked
    case notMarked
    case notWaiting
    case hasAllocations
    case originalNotMarked
    case invalidSettlementAmount
    case invalidAllocation
    case allocationExceedsOriginal
    case allocationExceedsSettlement
    case notSettlement
    case missingSettlementFxRate
    case refundAllocationMismatch
    case crossLedgerAllocation
    case unsupportedReimbursementStatus
    case unsupportedSettlementKind
    case invalidSettlementLink
    case noteTooLong
    case occurredAtOutOfRange

    var errorDescription: String? {
        switch self {
        case .transactionNotFound: ZanzanLocalization.string( "流水不存在或已删除")
        case .accountNotFound: ZanzanLocalization.string( "账户不存在或已删除")
        case .accountNotRecordable: ZanzanLocalization.string( "该账户已归档或不可用于记账")
        case .ledgerNotFound: ZanzanLocalization.string( "账本不存在或已删除")
        case .ledgerArchived: ZanzanLocalization.string( "账本已归档，无法登记到账")
        case .linkNotFound: ZanzanLocalization.string( "关联记录不存在或已删除")
        case .originalNotExpense: ZanzanLocalization.string( "只有支出流水可以报销或退款")
        case .alreadyMarked: ZanzanLocalization.string( "该流水已标记为待报销")
        case .notMarked: ZanzanLocalization.string( "该流水未标记为待报销")
        case .notWaiting: ZanzanLocalization.string( "只有待报销的流水可以结案")
        case .hasAllocations: ZanzanLocalization.string( "该流水已有报销记录，请先解除关联")
        case .originalNotMarked: ZanzanLocalization.string( "请先将支出标记为待报销")
        case .invalidSettlementAmount: ZanzanLocalization.string( "到账金额必须大于 0")
        case .invalidAllocation: ZanzanLocalization.string( "分摊明细无效：金额需大于 0 且不可重复选择同一笔流水")
        case .allocationExceedsOriginal: ZanzanLocalization.string( "累计分摊金额超过了原支出金额")
        case .allocationExceedsSettlement: ZanzanLocalization.string( "分摊合计超过了到账金额")
        case .notSettlement: ZanzanLocalization.string( "该流水不是报销或退款到账单")
        case .missingSettlementFxRate: ZanzanLocalization.string( "外币到账账户缺少汇率快照，请先记一笔该币种流水")
        case .refundAllocationMismatch: ZanzanLocalization.string( "退款分摊合计必须等于到账金额")
        case .crossLedgerAllocation: ZanzanLocalization.string( "原支出与到账单必须属于同一账本")
        case .unsupportedReimbursementStatus:
            ZanzanLocalization.string( "该流水的报销状态由更高版本创建，请升级 App 后操作")
        case .unsupportedSettlementKind:
            ZanzanLocalization.string( "到账标记或关联类型由更高版本创建，请升级 App 后重试")
        case .invalidSettlementLink:
            ZanzanLocalization.string( "报销/退款关联数据不完整或互相冲突，已停止重建")
        case .noteTooLong: ZanzanLocalization.string( "备注不能超过 \(DraftLimits.maxNoteLength) 字")
        case .occurredAtOutOfRange: ZanzanLocalization.string( "到账时间超出可记账范围")
        }
    }
}
