import Foundation
import SwiftData

/// 标签写路径命令（设计文档 5.6 / §4 软删语义）。不变量：同库（同 ledgerID 且活跃）
/// 不重名；流水只能挂全局标签或与流水同账本的标签；归档/软删标签不可挂新流水。
struct TagService {
    let context: ModelContext

    @discardableResult
    func createTag(_ draft: TagDraft) throws -> Tag {
        let v = try draft.validated()
        try ensureUniqueName(v.name, ledgerID: v.ledgerID, excluding: nil)
        let tag = Tag(name: v.name)
        tag.colorID = v.colorID
        tag.ledgerID = v.ledgerID
        tag.sortOrder = try activeCount(ledgerID: v.ledgerID)
        context.insert(tag)
        try context.save()
        return tag
    }

    func updateTag(uuid: UUID, draft: TagDraft) throws {
        let tag = try fetchActiveTag(uuid)
        let v = try draft.validated()
        // ponytail: 归属库创建后不可改——改库会破坏既有流水「全局或同账本」不变量，需求出现再做迁移路径
        guard v.ledgerID == tag.ledgerID else { throw TagServiceError.ledgerScopeImmutable }
        if v.name != tag.name {
            try ensureUniqueName(v.name, ledgerID: v.ledgerID, excluding: uuid)
        }
        tag.name = v.name
        tag.colorID = v.colorID
        tag.updatedAt = .now
        try context.save()
    }

    func setArchived(uuid: UUID, isArchived: Bool) throws {
        let tag = try fetchActiveTag(uuid)
        tag.isArchived = isArchived
        tag.updatedAt = .now
        try context.save()
    }

    /// 软删：标签直接软删（设计文档 §4），既有流水引用保留，恢复即回归。
    func softDeleteTag(uuid: UUID) throws {
        let tag = try fetchActiveTag(uuid)
        tag.isSoftDeleted = true
        tag.updatedAt = .now
        try context.save()
    }

    // MARK: - 流水挂/摘标签

    /// 幂等：已挂同一标签直接返回。归档/软删标签不可挂，跨账本标签不可挂。
    func attachTag(tagUUID: UUID, toTransaction transactionUUID: UUID) throws {
        let tag = try fetchActiveTag(tagUUID)
        guard !tag.isArchived else { throw TagServiceError.tagArchived }
        let tx = try fetchActiveTransaction(transactionUUID)
        guard tag.ledgerID == nil || tag.ledgerID == tx.ledgerID else {
            throw TagServiceError.ledgerMismatch
        }
        var tags = tx.tags ?? []
        guard !tags.contains(where: { $0.uuid == tagUUID }) else { return }
        tags.append(tag)
        tx.tags = tags
        tx.updatedAt = .now
        try context.save()
    }

    /// 幂等：未挂该标签直接返回。按 uuid 摘除，软删标签也可摘（清理场景）。
    func detachTag(tagUUID: UUID, fromTransaction transactionUUID: UUID) throws {
        let tx = try fetchActiveTransaction(transactionUUID)
        guard var tags = tx.tags, tags.contains(where: { $0.uuid == tagUUID }) else { return }
        tags.removeAll { $0.uuid == tagUUID }
        tx.tags = tags
        tx.updatedAt = .now
        try context.save()
    }

    // MARK: - 私有

    private func ensureUniqueName(_ name: String, ledgerID: UUID?, excluding excludedUUID: UUID?) throws {
        // #Predicate 不支持 UUID 与 UUID? 直接比较，按有无排除项分两个谓词
        let predicate: Predicate<Tag>
        if let excludedUUID {
            predicate = #Predicate {
                !$0.isSoftDeleted && $0.ledgerID == ledgerID && $0.name == name && $0.uuid != excludedUUID
            }
        } else {
            predicate = #Predicate { !$0.isSoftDeleted && $0.ledgerID == ledgerID && $0.name == name }
        }
        let duplicateCount = try context.fetchCount(FetchDescriptor<Tag>(predicate: predicate))
        guard duplicateCount == 0 else { throw TagServiceError.duplicateName }
    }

    private func activeCount(ledgerID: UUID?) throws -> Int {
        try context.fetchCount(
            FetchDescriptor<Tag>(predicate: #Predicate {
                !$0.isSoftDeleted && $0.ledgerID == ledgerID
            })
        )
    }

    private func fetchActiveTag(_ uuid: UUID) throws -> Tag {
        let descriptor = FetchDescriptor<Tag>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        )
        guard let tag = try context.fetch(descriptor).first else {
            throw TagServiceError.tagNotFound
        }
        return tag
    }

    private func fetchActiveTransaction(_ uuid: UUID) throws -> Transaction {
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        )
        guard let tx = try context.fetch(descriptor).first else {
            throw TagServiceError.transactionNotFound
        }
        return tx
    }
}

enum TagServiceError: LocalizedError {
    case tagNotFound
    case transactionNotFound
    case duplicateName
    case tagArchived
    case ledgerMismatch
    case ledgerScopeImmutable

    var errorDescription: String? {
        switch self {
        case .tagNotFound: String(localized: "标签不存在或已删除")
        case .transactionNotFound: String(localized: "流水不存在或已删除")
        case .duplicateName: String(localized: "已存在同名标签")
        case .tagArchived: String(localized: "标签已归档，不能挂到新流水；可先取消归档")
        case .ledgerMismatch: String(localized: "只能使用全局标签或本账本的标签")
        case .ledgerScopeImmutable: String(localized: "标签归属账本创建后不可修改")
        }
    }
}
