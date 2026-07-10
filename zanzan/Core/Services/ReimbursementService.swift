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
        let tx = try fetchActiveTransaction(transactionUUID)
        guard tx.kind == .expense else { throw ReimbursementServiceError.originalNotExpense }
        guard tx.reimbursementStatusRawValue.isEmpty else {
            throw tx.reimbursementStatus != nil
                ? ReimbursementServiceError.alreadyMarked
                : ReimbursementServiceError.unsupportedReimbursementStatus
        }
        tx.reimbursementStatusRawValue = ReimbursementStatus.waiting.rawValue
        tx.updatedAt = .now
        try context.save()
    }

    /// 取消垫付标记；已有分摊关联时阻断（须先解除关联）
    func unmarkReimbursement(transactionUUID: UUID) throws {
        let tx = try fetchActiveTransaction(transactionUUID)
        guard tx.reimbursementStatus != nil else { throw ReimbursementServiceError.notMarked }
        guard try allocatedAmount(originalID: tx.uuid) == 0 else {
            throw ReimbursementServiceError.hasAllocations
        }
        tx.reimbursementStatusRawValue = ""
        tx.updatedAt = .now
        try context.save()
    }

    /// 实报少于垫付时手动结案置 settled（5.5）
    func settleManually(transactionUUID: UUID) throws {
        let tx = try fetchActiveTransaction(transactionUUID)
        guard tx.reimbursementStatus == .waiting else { throw ReimbursementServiceError.notWaiting }
        tx.reimbursementStatusRawValue = ReimbursementStatus.settled.rawValue
        tx.updatedAt = .now
        try context.save()
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
        guard amountMinorUnits > 0 else { throw ReimbursementServiceError.invalidSettlementAmount }
        guard !allocations.isEmpty, allocations.allSatisfy({ $0.amountMinorUnits > 0 }) else {
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
            guard let rate = try FxRateProvider(context: context).rate(for: settlementCurrency),
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
            guard allocated + allocation.amountMinorUnits <= original.amountMinorUnits else {
                throw ReimbursementServiceError.allocationExceedsOriginal
            }
            originals.append(original)
        }

        // 「Σ 分摊 ≤ 到账金额」（§5.5）：全部同币种时保持精确整数比较（零行为变化）；
        // 涉及跨币种（垫付外币、本位币到账等）时各方按自身 fxRateToBase 折本位币，
        // 近似比较：Σ 折算分摊 ≤ 折算到账 × (1 + reimbursementToleranceRatio)
        // 退款须全额分摊（R4-M2）：月度总支出按到账单全额冲减、分类排行只冲减 Σ link，
        // 欠分摊差额会凭空消失——同币种要求精确相等，跨币种复用容差下界。
        // 报销维持 Σ ≤ 到账（允许部分报销，§5.4）
        let allocationTotal = allocations.reduce(0) { $0 + $1.amountMinorUnits }
        if originals.allSatisfy({ $0.currencyCode == settlementCurrency }) {
            guard allocationTotal <= amountMinorUnits else {
                throw ReimbursementServiceError.allocationExceedsSettlement
            }
            if kind == .refund {
                guard allocationTotal == amountMinorUnits else {
                    throw ReimbursementServiceError.refundAllocationMismatch
                }
            }
        } else {
            let convertedAllocationTotal = zip(originals, allocations).reduce(0) { sum, pair in
                sum + FxConversion.toBaseMinorUnits(pair.1.amountMinorUnits, rate: baseRate(of: pair.0))
            }
            let convertedSettlement = FxConversion.toBaseMinorUnits(
                amountMinorUnits, rate: settlementFxRate ?? 1
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

        // 到账单：income，不挂分类（统计口径由投影器剔除/冲减，见 Transaction+StatsAmounts）
        let settlement = Transaction(
            kind: .income, amountMinorUnits: amountMinorUnits, occurredAt: occurredAt, ledgerID: ledgerID
        )
        settlement.account = account
        settlement.currencyCode = settlementCurrency // 收支币种 = 账户币种（§5.4）
        settlement.fxRateToBase = settlementFxRate // 非 CNY 必填（上方已校验），CNY 恒 nil
        settlement.note = note
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
            try recomputeOriginalStatus(original)
        }
        try context.save()
        return settlement
    }

    // MARK: - 解除关联

    /// 软删到账单：级联软删其全部分摊关联，回退受影响原单状态（5.5）
    func removeSettlement(transactionUUID: UUID) throws {
        let settlement = try fetchActiveTransaction(transactionUUID)
        guard settlement.settlementKind != nil else { throw ReimbursementServiceError.notSettlement }
        let links = try activeLinks(settlementID: settlement.uuid)
        for link in links {
            link.isSoftDeleted = true
            link.updatedAt = .now
        }
        settlement.isSoftDeleted = true
        settlement.updatedAt = .now
        for link in links {
            if let original = try? fetchActiveTransaction(link.originalTransactionID) {
                try recomputeOriginalStatus(original)
            }
        }
        try context.save()
    }

    /// 恢复被 removeSettlement 软删的到账单（§4 撤销恢复按相反方向执行）：
    /// 恢复到账单流水与其被级联软删的关联行，重算受影响原单状态与到账单 settlementKind 标记。
    /// 软删期间若已另记到账导致恢复后原单超额分摊，先行阻断（不落任何改动）。
    func restoreSettlement(transactionUUID: UUID) throws {
        let settlement = try fetchSoftDeletedTransaction(transactionUUID)
        guard settlement.settlementKind != nil else { throw ReimbursementServiceError.notSettlement }
        // ponytail: 无法区分「removeSettlement 级联软删的行」与「此前手动 removeLink 删的行」，
        // 此处全部恢复；如需精确恢复可将来在 TransactionLink 上加删除来源标记
        let links = try softDeletedLinks(settlementID: settlement.uuid)

        // 先校验后落改：恢复不得使任一原单超额分摊（§5.5 Σ 分摊 ≤ 原单金额）
        var restoredByOriginal: [UUID: Int] = [:]
        for link in links {
            restoredByOriginal[link.originalTransactionID, default: 0] += link.amountMinorUnits
        }
        for (originalID, restored) in restoredByOriginal {
            guard let original = try? fetchActiveTransaction(originalID) else { continue }
            let allocated = try allocatedAmount(originalID: originalID)
            guard allocated + restored <= original.amountMinorUnits else {
                throw ReimbursementServiceError.allocationExceedsOriginal
            }
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
        for originalID in restoredByOriginal.keys {
            if let original = try? fetchActiveTransaction(originalID) {
                try recomputeOriginalStatus(original)
            }
        }
        try context.save()
    }

    /// 软删单条分摊关联：原单状态回退；到账单关联清零时重算冗余标记（回落为普通收入）
    func removeLink(linkUUID: UUID) throws {
        let descriptor = FetchDescriptor<TransactionLink>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == linkUUID }
        )
        guard let link = try context.fetch(descriptor).first else {
            throw ReimbursementServiceError.linkNotFound
        }
        link.isSoftDeleted = true
        link.updatedAt = .now
        if let original = try? fetchActiveTransaction(link.originalTransactionID) {
            try recomputeOriginalStatus(original)
        }
        if let settlement = try? fetchActiveTransaction(link.settlementTransactionID),
           try activeLinks(settlementID: settlement.uuid).isEmpty {
            settlement.settlementKindRawValue = "" // 冗余标记可由关联表全量重算（5.4）
            settlement.updatedAt = .now
        }
        try context.save()
    }

    // MARK: - 私有

    /// 流水折本位币所用汇率：CNY 恒 1；外币取记账时快照，快照缺失（历史坏数据，
    /// §5.4 本应由命令层强制非空）按 1:1 兜底——口径同 FxRateProvider「无快照按 1:1 折算」约定
    private func baseRate(of tx: Transaction) -> Decimal {
        guard tx.currencyCode != FxConversion.baseCurrencyCode else { return 1 }
        return tx.fxRateToBase ?? 1
    }

    /// 按 Σ 分摊覆盖情况推进/回退原单状态：全额覆盖 → settled，否则 waiting。
    /// 未标记垫付的原单（退款原单）不参与状态机。
    private func recomputeOriginalStatus(_ original: Transaction) throws {
        guard original.reimbursementStatus != nil else { return }
        let allocated = try allocatedAmount(originalID: original.uuid)
        let status: ReimbursementStatus = allocated >= original.amountMinorUnits ? .settled : .waiting
        original.reimbursementStatusRawValue = status.rawValue
        original.updatedAt = .now
    }

    /// 原单已报销/已退款额 = Σ 其活跃关联行金额（派生值不落库，5.5）
    private func allocatedAmount(originalID: UUID) throws -> Int {
        let links = try context.fetch(FetchDescriptor<TransactionLink>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.originalTransactionID == originalID }
        ))
        return links.reduce(0) { $0 + $1.amountMinorUnits }
    }

    private func activeLinks(settlementID: UUID) throws -> [TransactionLink] {
        try context.fetch(FetchDescriptor<TransactionLink>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.settlementTransactionID == settlementID }
        ))
    }

    private func softDeletedLinks(settlementID: UUID) throws -> [TransactionLink] {
        try context.fetch(FetchDescriptor<TransactionLink>(
            predicate: #Predicate { $0.isSoftDeleted && $0.settlementTransactionID == settlementID }
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
        return account
    }

    private func ensureActiveLedger(_ uuid: UUID) throws {
        let count = try context.fetchCount(
            FetchDescriptor<Ledger>(predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid })
        )
        guard count > 0 else { throw ReimbursementServiceError.ledgerNotFound }
    }
}

enum ReimbursementServiceError: LocalizedError {
    case transactionNotFound
    case accountNotFound
    case ledgerNotFound
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

    var errorDescription: String? {
        switch self {
        case .transactionNotFound: String(localized: "流水不存在或已删除")
        case .accountNotFound: String(localized: "账户不存在或已删除")
        case .ledgerNotFound: String(localized: "账本不存在或已删除")
        case .linkNotFound: String(localized: "关联记录不存在或已删除")
        case .originalNotExpense: String(localized: "只有支出流水可以报销或退款")
        case .alreadyMarked: String(localized: "该流水已标记为待报销")
        case .notMarked: String(localized: "该流水未标记为待报销")
        case .notWaiting: String(localized: "只有待报销的流水可以结案")
        case .hasAllocations: String(localized: "该流水已有报销记录，请先解除关联")
        case .originalNotMarked: String(localized: "请先将支出标记为待报销")
        case .invalidSettlementAmount: String(localized: "到账金额必须大于 0")
        case .invalidAllocation: String(localized: "分摊明细无效：金额需大于 0 且不可重复选择同一笔流水")
        case .allocationExceedsOriginal: String(localized: "累计分摊金额超过了原支出金额")
        case .allocationExceedsSettlement: String(localized: "分摊合计超过了到账金额")
        case .notSettlement: String(localized: "该流水不是报销或退款到账单")
        case .missingSettlementFxRate: String(localized: "外币到账账户缺少汇率快照，请先记一笔该币种流水")
        case .refundAllocationMismatch: String(localized: "退款分摊合计必须等于到账金额")
        case .crossLedgerAllocation: String(localized: "原支出与到账单必须属于同一账本")
        case .unsupportedReimbursementStatus:
            String(localized: "该流水的报销状态由更高版本创建，请升级 App 后操作")
        }
    }
}
