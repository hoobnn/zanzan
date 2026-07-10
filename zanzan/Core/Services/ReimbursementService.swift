import Foundation
import SwiftData

/// 报销/退款写路径命令（设计文档 5.4 报销流程 / 5.5 命令层不变量）。
/// 原单 kind 终生保持 expense；到账单是独立 income（settlementKind 冗余标记），
/// 经 TransactionLink 一行一次分摊建 M:N 关联；waiting → settled 由分摊覆盖驱动，
/// 解除关联自动回退。不变量：单张原单 Σ 分摊 ≤ 原单金额；单笔到账单 Σ 分摊 ≤ 到账金额。
struct ReimbursementService {
    /// 一次分摊：到账单对某张原单的分摊金额（分，以原单币种计）。
    /// ponytail: MVP 锁 CNY 直接同币种比较；跨币种按 fxRateToBase 折算 + 容差留待多币种切片。
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

    /// 把既有支出流水标记为垫付（待报销），进入 waiting 状态
    func markAwaitingReimbursement(transactionUUID: UUID) throws {
        let tx = try fetchActiveTransaction(transactionUUID)
        guard tx.kind == .expense else { throw ReimbursementServiceError.originalNotExpense }
        guard tx.reimbursementStatus == nil else { throw ReimbursementServiceError.alreadyMarked }
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
        let allocationTotal = allocations.reduce(0) { $0 + $1.amountMinorUnits }
        guard allocationTotal <= amountMinorUnits else {
            throw ReimbursementServiceError.allocationExceedsSettlement
        }

        try ensureActiveLedger(ledgerID)
        let account = try fetchActiveAccount(accountUUID)

        // 校验各原单：支出单、报销须已标记垫付、累计分摊不超原单金额
        var originals: [Transaction] = []
        for allocation in allocations {
            let original = try fetchActiveTransaction(allocation.originalTransactionUUID)
            guard original.kind == .expense else { throw ReimbursementServiceError.originalNotExpense }
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

        // 到账单：income，不挂分类（统计口径由投影器剔除/冲减，见 Transaction+StatsAmounts）
        let settlement = Transaction(
            kind: .income, amountMinorUnits: amountMinorUnits, occurredAt: occurredAt, ledgerID: ledgerID
        )
        settlement.account = account
        settlement.currencyCode = account.currencyCode // MVP 全 CNY；fxRateToBase 恒 nil
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
        }
    }
}
