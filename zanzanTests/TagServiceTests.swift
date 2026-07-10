import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct TagServiceTests {
    private struct Env {
        let context: ModelContext
        let ledgerID: UUID
        let accountUUID: UUID
        let categoryUUID: UUID
    }

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    private func makeEnv() throws -> Env {
        let context = try makeContext()
        let ledger = try LedgerService(context: context).createLedger(LedgerDraft(name: "测试账本"))
        var accountDraft = AccountDraft()
        accountDraft.name = "现金"
        let account = try AccountService(context: context).createAccount(accountDraft)
        var categoryDraft = CategoryDraft()
        categoryDraft.name = "餐饮"
        let category = try CategoryService(context: context).createCategory(categoryDraft)
        return Env(context: context, ledgerID: ledger.uuid, accountUUID: account.uuid, categoryUUID: category.uuid)
    }

    @discardableResult
    private func makeTag(_ context: ModelContext, name: String, ledgerID: UUID? = nil) throws -> Tag {
        var draft = TagDraft()
        draft.name = name
        draft.ledgerID = ledgerID
        return try TagService(context: context).createTag(draft)
    }

    @discardableResult
    private func record(_ env: Env) throws -> Transaction {
        var draft = TransactionDraft()
        draft.kind = .expense
        draft.amountString = "10"
        draft.accountUUID = env.accountUUID
        draft.categoryUUID = env.categoryUUID
        return try TransactionService(context: env.context).recordTransaction(draft, ledgerID: env.ledgerID)
    }

    // MARK: - 增 / 改

    @Test func 创建标签追加排序() throws {
        let context = try makeContext()
        let first = try makeTag(context, name: "旅行")
        let second = try makeTag(context, name: "报销")
        #expect(first.sortOrder == 0)
        #expect(second.sortOrder == 1)
        #expect(first.ledgerID == nil)
        #expect(first.colorID == "blue")
    }

    @Test func 同库重名被拒() throws {
        let context = try makeContext()
        try makeTag(context, name: "旅行")
        #expect(throws: TagServiceError.duplicateName) {
            try makeTag(context, name: "旅行")
        }
    }

    @Test func 不同库同名允许() throws {
        let context = try makeContext()
        try makeTag(context, name: "旅行")
        let scoped = try makeTag(context, name: "旅行", ledgerID: UUID())
        #expect(scoped.name == "旅行")
    }

    @Test func 软删后同名可再建() throws {
        let context = try makeContext()
        let tag = try makeTag(context, name: "旅行")
        try TagService(context: context).softDeleteTag(uuid: tag.uuid)
        let recreated = try makeTag(context, name: "旅行")
        #expect(recreated.uuid != tag.uuid)
    }

    @Test func 更新改名改色() throws {
        let context = try makeContext()
        let tag = try makeTag(context, name: "旅行")
        var draft = TagDraft(tag: tag)
        draft.name = "出差"
        draft.colorID = "red"
        try TagService(context: context).updateTag(uuid: tag.uuid, draft: draft)
        #expect(tag.name == "出差")
        #expect(tag.colorID == "red")
    }

    @Test func 更新撞已有名被拒() throws {
        let context = try makeContext()
        try makeTag(context, name: "旅行")
        let tag = try makeTag(context, name: "出差")
        var draft = TagDraft(tag: tag)
        draft.name = "旅行"
        #expect(throws: TagServiceError.duplicateName) {
            try TagService(context: context).updateTag(uuid: tag.uuid, draft: draft)
        }
    }

    @Test func 更新保持原名不算重名() throws {
        let context = try makeContext()
        let tag = try makeTag(context, name: "旅行")
        var draft = TagDraft(tag: tag)
        draft.colorID = "green"
        try TagService(context: context).updateTag(uuid: tag.uuid, draft: draft)
        #expect(tag.colorID == "green")
    }

    @Test func 更新改归属库被拒() throws {
        let context = try makeContext()
        let tag = try makeTag(context, name: "旅行")
        var draft = TagDraft(tag: tag)
        draft.ledgerID = UUID()
        #expect(throws: TagServiceError.ledgerScopeImmutable) {
            try TagService(context: context).updateTag(uuid: tag.uuid, draft: draft)
        }
    }

    // MARK: - 归档 / 软删

    @Test func 归档与取消归档() throws {
        let context = try makeContext()
        let tag = try makeTag(context, name: "旅行")
        let service = TagService(context: context)
        try service.setArchived(uuid: tag.uuid, isArchived: true)
        #expect(tag.isArchived)
        try service.setArchived(uuid: tag.uuid, isArchived: false)
        #expect(!tag.isArchived)
    }

    @Test func 有流水引用的标签仍可直接软删且引用保留() throws {
        let env = try makeEnv()
        let tag = try makeTag(env.context, name: "旅行")
        let tx = try record(env)
        let service = TagService(context: env.context)
        try service.attachTag(tagUUID: tag.uuid, toTransaction: tx.uuid)
        try service.softDeleteTag(uuid: tag.uuid)
        #expect(tag.isSoftDeleted)
        #expect(tx.tags?.contains { $0.uuid == tag.uuid } == true)
    }

    @Test func 软删标签不可再改() throws {
        let context = try makeContext()
        let tag = try makeTag(context, name: "旅行")
        let service = TagService(context: context)
        try service.softDeleteTag(uuid: tag.uuid)
        #expect(throws: TagServiceError.tagNotFound) {
            try service.updateTag(uuid: tag.uuid, draft: TagDraft(tag: tag))
        }
    }

    // MARK: - 挂 / 摘标签

    @Test func 挂全局标签成功且幂等() throws {
        let env = try makeEnv()
        let tag = try makeTag(env.context, name: "旅行")
        let tx = try record(env)
        let service = TagService(context: env.context)
        try service.attachTag(tagUUID: tag.uuid, toTransaction: tx.uuid)
        try service.attachTag(tagUUID: tag.uuid, toTransaction: tx.uuid) // 幂等
        #expect(tx.tags?.count == 1)
    }

    @Test func 挂同账本标签成功() throws {
        let env = try makeEnv()
        let tag = try makeTag(env.context, name: "旅行", ledgerID: env.ledgerID)
        let tx = try record(env)
        try TagService(context: env.context).attachTag(tagUUID: tag.uuid, toTransaction: tx.uuid)
        #expect(tx.tags?.first?.uuid == tag.uuid)
    }

    @Test func 跨账本标签不可挂() throws {
        let env = try makeEnv()
        let tag = try makeTag(env.context, name: "旅行", ledgerID: UUID())
        let tx = try record(env)
        #expect(throws: TagServiceError.ledgerMismatch) {
            try TagService(context: env.context).attachTag(tagUUID: tag.uuid, toTransaction: tx.uuid)
        }
    }

    @Test func 归档标签不可挂() throws {
        let env = try makeEnv()
        let tag = try makeTag(env.context, name: "旅行")
        let tx = try record(env)
        let service = TagService(context: env.context)
        try service.setArchived(uuid: tag.uuid, isArchived: true)
        #expect(throws: TagServiceError.tagArchived) {
            try service.attachTag(tagUUID: tag.uuid, toTransaction: tx.uuid)
        }
    }

    @Test func 软删标签不可挂() throws {
        let env = try makeEnv()
        let tag = try makeTag(env.context, name: "旅行")
        let tx = try record(env)
        let service = TagService(context: env.context)
        try service.softDeleteTag(uuid: tag.uuid)
        #expect(throws: TagServiceError.tagNotFound) {
            try service.attachTag(tagUUID: tag.uuid, toTransaction: tx.uuid)
        }
    }

    @Test func 软删流水不可挂摘() throws {
        let env = try makeEnv()
        let tag = try makeTag(env.context, name: "旅行")
        let tx = try record(env)
        let service = TagService(context: env.context)
        try service.attachTag(tagUUID: tag.uuid, toTransaction: tx.uuid)
        try TransactionService(context: env.context).softDeleteTransaction(uuid: tx.uuid)
        #expect(throws: TagServiceError.transactionNotFound) {
            try service.attachTag(tagUUID: tag.uuid, toTransaction: tx.uuid)
        }
        #expect(throws: TagServiceError.transactionNotFound) {
            try service.detachTag(tagUUID: tag.uuid, fromTransaction: tx.uuid)
        }
    }

    @Test func 摘标签成功且幂等() throws {
        let env = try makeEnv()
        let tag = try makeTag(env.context, name: "旅行")
        let tx = try record(env)
        let service = TagService(context: env.context)
        try service.attachTag(tagUUID: tag.uuid, toTransaction: tx.uuid)
        try service.detachTag(tagUUID: tag.uuid, fromTransaction: tx.uuid)
        try service.detachTag(tagUUID: tag.uuid, fromTransaction: tx.uuid) // 幂等
        #expect(tx.tags?.isEmpty ?? true)
    }

    // MARK: - 撤销恢复

    @Test func 撤销软删恢复标签() throws {
        let context = try makeContext()
        let service = TagService(context: context)
        let tag = try makeTag(context, name: "旅行")
        try service.softDeleteTag(uuid: tag.uuid)
        try service.undoSoftDeleteTag(uuid: tag.uuid)
        #expect(!tag.isSoftDeleted)
    }

    @Test func 同库活跃重名阻断恢复() throws {
        let context = try makeContext()
        let service = TagService(context: context)
        let tag = try makeTag(context, name: "旅行")
        try service.softDeleteTag(uuid: tag.uuid)
        try makeTag(context, name: "旅行") // 删除期间新建了同名标签
        #expect(throws: TagServiceError.duplicateName) {
            try service.undoSoftDeleteTag(uuid: tag.uuid)
        }
        #expect(tag.isSoftDeleted)
    }

    @Test func 双重恢复幂等() throws {
        let context = try makeContext()
        let service = TagService(context: context)
        let tag = try makeTag(context, name: "旅行")
        try service.softDeleteTag(uuid: tag.uuid)
        try service.undoSoftDeleteTag(uuid: tag.uuid)
        try service.undoSoftDeleteTag(uuid: tag.uuid) // 查重排除自身，不误伤
        #expect(!tag.isSoftDeleted)
    }
}
