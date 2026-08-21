import Foundation
import SwiftData

/// 记一笔/编辑页的组合写命令。
///
/// 主体、标签、报销状态先在同一 ModelContext 内完成校验与暂存，附件全部写入后统一
/// `zanzanSave()`；任一步失败都回滚数据库，附件层同时补偿删除本批已写文件。
struct TransactionCompositeService {
    let context: ModelContext
    let attachmentRootDirectory: URL?

    init(context: ModelContext, attachmentRootDirectory: URL? = nil) {
        self.context = context
        self.attachmentRootDirectory = attachmentRootDirectory
    }

    /// 新建完整流水；所有组成部分共享一个数据库提交边界。
    @discardableResult
    func create(
        _ draft: TransactionDraft,
        ledgerID: UUID,
        tagUUIDs: Set<UUID>,
        isReimbursementMarked: Bool,
        attachments: [Data]
    ) throws -> Transaction {
        do {
            let transaction = try TransactionService(context: context)
                .stageTransaction(draft, ledgerID: ledgerID)
            try TagService(context: context)
                .stageTagSelection(tagUUIDs, on: transaction)
            try ReimbursementService(context: context)
                .stageReimbursementSelection(isReimbursementMarked, on: transaction)
            try commit(transaction: transaction, attachments: attachments)
            return transaction
        } catch {
            context.rollback()
            throw error
        }
    }

    /// 编辑完整流水；主体、标签、报销状态与新增附件共享一个数据库提交边界。
    @discardableResult
    func update(
        uuid: UUID,
        draft: TransactionDraft,
        tagUUIDs: Set<UUID>,
        isReimbursementMarked: Bool,
        attachments: [Data]
    ) throws -> Transaction {
        do {
            let transaction = try TransactionService(context: context)
                .stageUpdateTransaction(uuid: uuid, draft: draft)
            try TagService(context: context)
                .stageTagSelection(tagUUIDs, on: transaction)
            try ReimbursementService(context: context)
                .stageReimbursementSelection(isReimbursementMarked, on: transaction)
            try commit(transaction: transaction, attachments: attachments)
            return transaction
        } catch {
            context.rollback()
            throw error
        }
    }

    private func commit(transaction: Transaction, attachments: [Data]) throws {
        guard !attachments.isEmpty else {
            try context.zanzanSave()
            return
        }
        _ = try AttachmentStore(
            context: context,
            rootDirectory: attachmentRootDirectory
        ).saveAll(data: attachments, for: transaction)
    }
}
