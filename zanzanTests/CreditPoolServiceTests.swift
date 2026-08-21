import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct CreditPoolServiceTests {
    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    private func makeCreditCard(context: ModelContext, name: String = "信用卡") -> Account {
        let card = Account(name: name, kind: .credit)
        context.insert(card)
        return card
    }

    // MARK: - 创建/更新

    @Test func 创建授信池成功并归一化() throws {
        let context = try makeContext()
        let service = CreditPoolService(context: context)
        var draft = CreditPoolDraft()
        draft.name = "  招商银行  "
        draft.totalLimitString = "1000"
        let pool = try service.createPool(draft)
        #expect(pool.name == "招商银行")
        #expect(pool.totalLimitMinorUnits == 100_000)
        #expect(pool.currencyCode == "CNY")
    }

    @Test func 空名或非法额度抛错() throws {
        var emptyName = CreditPoolDraft()
        emptyName.totalLimitString = "1000"
        #expect(throws: CreditPoolDraftError.self) { try emptyName.validated() }

        var zeroLimit = CreditPoolDraft()
        zeroLimit.name = "招商银行"
        zeroLimit.totalLimitString = "0"
        #expect(throws: CreditPoolDraftError.self) { try zeroLimit.validated() }
    }

    @Test func 名称或备注超长抛错() {
        var draft = CreditPoolDraft()
        draft.name = String(repeating: "池", count: DraftLimits.maxNameLength + 1)
        draft.totalLimitString = "1000"
        #expect(throws: CreditPoolDraftError.nameTooLong) { try draft.validated() }

        draft.name = "授信池"
        draft.note = String(repeating: "备", count: DraftLimits.maxNoteLength + 1)
        #expect(throws: CreditPoolDraftError.noteTooLong) { try draft.validated() }
    }

    @Test func 币种代码归一化并拒绝非法格式() throws {
        var draft = CreditPoolDraft()
        draft.name = "美元授信"
        draft.totalLimitString = "1000"
        draft.currencyCode = " usd "
        #expect(try draft.validated().currencyCode == "USD")

        for code in ["US", "USDX", "US1", ""] {
            draft.currencyCode = code
            #expect(throws: CreditPoolDraftError.self) { try draft.validated() }
        }
    }

    @Test func 更新授信池成功() throws {
        let context = try makeContext()
        let service = CreditPoolService(context: context)
        var draft = CreditPoolDraft()
        draft.name = "招商银行"
        draft.totalLimitString = "1000"
        let pool = try service.createPool(draft)

        draft.name = "招行总授信"
        draft.totalLimitString = "2000"
        try service.updatePool(uuid: pool.uuid, draft: draft)
        #expect(pool.name == "招行总授信")
        #expect(pool.totalLimitMinorUnits == 200_000)
    }

    @Test func 更新不存在或已软删的池抛错() throws {
        let context = try makeContext()
        let service = CreditPoolService(context: context)
        var draft = CreditPoolDraft()
        draft.name = "招商银行"
        draft.totalLimitString = "1000"
        let pool = try service.createPool(draft)
        try service.softDeletePool(uuid: pool.uuid)
        #expect(throws: CreditPoolServiceError.self) {
            try service.updatePool(uuid: pool.uuid, draft: draft)
        }
    }

    // MARK: - 绑定/解绑

    @Test func 信用卡绑定与解绑成功() throws {
        let context = try makeContext()
        let service = CreditPoolService(context: context)
        var draft = CreditPoolDraft()
        draft.name = "招商银行"
        draft.totalLimitString = "1000"
        let pool = try service.createPool(draft)
        let card = makeCreditCard(context: context)
        try context.save()

        try service.bindCard(accountUUID: card.uuid, toPool: pool.uuid)
        #expect(card.creditPoolID == pool.uuid)

        try service.unbindCard(accountUUID: card.uuid)
        #expect(card.creditPoolID == nil)
    }

    @Test func 非信用卡账户入池抛错() throws {
        let context = try makeContext()
        let service = CreditPoolService(context: context)
        var draft = CreditPoolDraft()
        draft.name = "招商银行"
        draft.totalLimitString = "1000"
        let pool = try service.createPool(draft)
        let fund = Account(name: "现金", kind: .fund)
        context.insert(fund)
        try context.save()

        #expect(throws: CreditPoolServiceError.self) {
            try service.bindCard(accountUUID: fund.uuid, toPool: pool.uuid)
        }
        #expect(fund.creditPoolID == nil)
    }

    @Test func 币种不一致入池抛错() throws {
        let context = try makeContext()
        let service = CreditPoolService(context: context)
        var draft = CreditPoolDraft()
        draft.name = "花旗银行"
        draft.totalLimitString = "1000"
        draft.currencyCode = "USD"
        let pool = try service.createPool(draft)
        let card = makeCreditCard(context: context) // 默认 CNY
        try context.save()

        #expect(throws: CreditPoolServiceError.self) {
            try service.bindCard(accountUUID: card.uuid, toPool: pool.uuid)
        }
    }

    @Test func 软删账户或软删池不可绑定() throws {
        let context = try makeContext()
        let service = CreditPoolService(context: context)
        var draft = CreditPoolDraft()
        draft.name = "招商银行"
        draft.totalLimitString = "1000"
        let pool = try service.createPool(draft)
        let deletedCard = makeCreditCard(context: context)
        deletedCard.isSoftDeleted = true
        let card = makeCreditCard(context: context)
        try context.save()

        #expect(throws: CreditPoolServiceError.self) {
            try service.bindCard(accountUUID: deletedCard.uuid, toPool: pool.uuid)
        }

        try service.softDeletePool(uuid: pool.uuid)
        #expect(throws: CreditPoolServiceError.self) {
            try service.bindCard(accountUUID: card.uuid, toPool: pool.uuid)
        }
    }

    // MARK: - 软删除

    @Test func 软删池保留成员关系供精确恢复() throws {
        let context = try makeContext()
        let service = CreditPoolService(context: context)
        var draft = CreditPoolDraft()
        draft.name = "招商银行"
        draft.totalLimitString = "1000"
        let pool = try service.createPool(draft)
        let cardA = makeCreditCard(context: context, name: "卡A")
        let cardB = makeCreditCard(context: context, name: "卡B")
        try context.save()
        try service.bindCard(accountUUID: cardA.uuid, toPool: pool.uuid)
        try service.bindCard(accountUUID: cardB.uuid, toPool: pool.uuid)

        try service.softDeletePool(uuid: pool.uuid)
        #expect(pool.isSoftDeleted)
        #expect(cardA.creditPoolID == pool.uuid)
        #expect(cardB.creditPoolID == pool.uuid)
        #expect(!cardA.isSoftDeleted)
    }

    // MARK: - 撤销恢复

    @Test func 撤销软删恢复池与原成员关系() throws {
        let context = try makeContext()
        let service = CreditPoolService(context: context)
        var draft = CreditPoolDraft()
        draft.name = "招商银行"
        draft.totalLimitString = "1000"
        let pool = try service.createPool(draft)
        let card = makeCreditCard(context: context)
        try context.save()
        try service.bindCard(accountUUID: card.uuid, toPool: pool.uuid)
        try service.softDeletePool(uuid: pool.uuid)
        try service.undoSoftDeletePool(uuid: pool.uuid)
        #expect(!pool.isSoftDeleted)
        #expect(card.creditPoolID == pool.uuid)
    }

    @Test func 双重恢复幂等() throws {
        let context = try makeContext()
        let service = CreditPoolService(context: context)
        var draft = CreditPoolDraft()
        draft.name = "招商银行"
        draft.totalLimitString = "1000"
        let pool = try service.createPool(draft)
        try service.softDeletePool(uuid: pool.uuid)
        try service.undoSoftDeletePool(uuid: pool.uuid)
        try service.undoSoftDeletePool(uuid: pool.uuid)
        #expect(!pool.isSoftDeleted)
    }
}
