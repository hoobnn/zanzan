import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct TransactionCompositeServiceTests {
    private struct Fixture {
        let context: ModelContext
        let ledger: Ledger
        let cash: Account
        let dining: Category
        let travelTag: Tag
        let workTag: Tag
        let attachmentDirectory: URL

        func tearDown() {
            try? FileManager.default.removeItem(at: attachmentDirectory)
        }
    }

    private func makeFixture() throws -> Fixture {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let ledger = try LedgerService(context: context).createLedger(LedgerDraft(name: "日常"))

        var accountDraft = AccountDraft()
        accountDraft.name = "现金"
        let cash = try AccountService(context: context).createAccount(accountDraft)

        var categoryDraft = CategoryDraft()
        categoryDraft.name = "餐饮"
        let dining = try CategoryService(context: context).createCategory(categoryDraft)

        var travelDraft = TagDraft()
        travelDraft.name = "旅行"
        let travelTag = try TagService(context: context).createTag(travelDraft)
        var workDraft = TagDraft()
        workDraft.name = "工作"
        let workTag = try TagService(context: context).createTag(workDraft)

        let attachmentDirectory = FileManager.default.temporaryDirectory.appending(
            path: "TransactionCompositeServiceTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        return Fixture(
            context: context,
            ledger: ledger,
            cash: cash,
            dining: dining,
            travelTag: travelTag,
            workTag: workTag,
            attachmentDirectory: attachmentDirectory
        )
    }

    private func expenseDraft(_ fixture: Fixture, amount: String = "25.50") -> TransactionDraft {
        var draft = TransactionDraft()
        draft.kind = .expense
        draft.amountString = amount
        draft.accountUUID = fixture.cash.uuid
        draft.categoryUUID = fixture.dining.uuid
        return draft
    }

    @Test func 新建主体标签报销与附件一次提交后可完整读回() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let receipt = Data("票据一".utf8)

        let created = try TransactionCompositeService(
            context: fixture.context,
            attachmentRootDirectory: fixture.attachmentDirectory
        ).create(
            expenseDraft(fixture),
            ledgerID: fixture.ledger.uuid,
            tagUUIDs: [fixture.travelTag.uuid],
            isReimbursementMarked: true,
            attachments: [receipt]
        )

        let stored = try #require(
            try TransactionListFilter(ledgerID: fixture.ledger.uuid)
                .fetch(in: fixture.context)
                .first
        )
        #expect(stored.uuid == created.uuid)
        #expect(stored.amountMinorUnits == 2_550)
        #expect(Set(stored.tags?.map(\.uuid) ?? []) == [fixture.travelTag.uuid])
        #expect(stored.reimbursementStatus == .waiting)
        let fileName = try #require(stored.attachmentFileNames.first)
        #expect(
            try AttachmentStore(
                context: fixture.context,
                rootDirectory: fixture.attachmentDirectory
            ).load(fileName) == receipt
        )
    }

    @Test func 编辑主体标签报销与新增附件后可完整读回() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let service = TransactionCompositeService(
            context: fixture.context,
            attachmentRootDirectory: fixture.attachmentDirectory
        )
        let firstReceipt = Data("票据一".utf8)
        let transaction = try service.create(
            expenseDraft(fixture),
            ledgerID: fixture.ledger.uuid,
            tagUUIDs: [fixture.travelTag.uuid],
            isReimbursementMarked: true,
            attachments: [firstReceipt]
        )
        var editedDraft = expenseDraft(fixture, amount: "30")
        editedDraft.note = "编辑后"
        editedDraft.locationName = "公司"
        editedDraft.locationLatitudeString = "31.2304"
        editedDraft.locationLongitudeString = "121.4737"
        editedDraft.isExcludedFromBudget = true
        let secondReceipt = Data("票据二".utf8)

        let updated = try service.update(
            uuid: transaction.uuid,
            draft: editedDraft,
            tagUUIDs: [fixture.workTag.uuid],
            isReimbursementMarked: false,
            attachments: [secondReceipt]
        )

        let stored = try #require(
            try TransactionListFilter(ledgerID: fixture.ledger.uuid)
                .fetch(in: fixture.context)
                .first
        )
        #expect(stored.uuid == updated.uuid)
        #expect(stored.amountMinorUnits == 3_000)
        #expect(stored.note == "编辑后")
        #expect(stored.locationName == "公司")
        #expect(abs((stored.locationLatitude ?? 0) - 31.2304) < 0.000_000_1)
        #expect(abs((stored.locationLongitude ?? 0) - 121.4737) < 0.000_000_1)
        #expect(stored.isExcludedFromBudget)
        #expect(Set(stored.tags?.map(\.uuid) ?? []) == [fixture.workTag.uuid])
        #expect(stored.reimbursementStatus == nil)
        #expect(stored.attachmentFileNames.count == 2)
        let store = AttachmentStore(
            context: fixture.context,
            rootDirectory: fixture.attachmentDirectory
        )
        #expect(
            try Set(stored.attachmentFileNames.map { try store.load($0) })
                == Set([firstReceipt, secondReceipt])
        )
    }

    @Test func 最终保存失败时主体关联状态与已写附件全部回滚() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let schemaVersionKey = CompatibilityWriteGate.key
        let schemaMeta = try #require(try fixture.context.fetch(FetchDescriptor<AppMeta>(
            predicate: #Predicate {
                !$0.isSoftDeleted && $0.key == schemaVersionKey
            }
        )).first)
        schemaMeta.value = "99.0.0"
        try fixture.context.save() // 测试布置：模拟数据库已由更高版本写入

        #expect(
            throws: CompatibilityWriteGateError.requiresNewerApp(required: "99.0.0")
        ) {
            try TransactionCompositeService(
                context: fixture.context,
                attachmentRootDirectory: fixture.attachmentDirectory
            ).create(
                self.expenseDraft(fixture),
                ledgerID: fixture.ledger.uuid,
                tagUUIDs: [fixture.travelTag.uuid],
                isReimbursementMarked: true,
                attachments: [Data("票据一".utf8), Data("票据二".utf8)]
            )
        }

        #expect(
            try TransactionListFilter(ledgerID: fixture.ledger.uuid)
                .fetch(in: fixture.context)
                .isEmpty
        )
        if FileManager.default.fileExists(atPath: fixture.attachmentDirectory.path) {
            #expect(
                try FileManager.default.contentsOfDirectory(
                    at: fixture.attachmentDirectory,
                    includingPropertiesForKeys: nil
                ).isEmpty
            )
        }
    }
}
