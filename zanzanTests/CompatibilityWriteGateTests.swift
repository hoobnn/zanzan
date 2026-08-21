import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct CompatibilityWriteGateTests {
    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    @Test func 当前版本派生自迁移计划末位() {
        #expect(
            CompatibilityWriteGate.currentVersion
                == ZanzanMigrationPlan.schemas.last?.versionIdentifier
        )
    }

    @Test func 首次业务写入登记当前Schema版本() throws {
        let context = try makeContext()
        _ = try LedgerService(context: context).createLedger(LedgerDraft(name: "日常"))
        let key = CompatibilityWriteGate.key
        let meta = try #require(
            try context.fetch(
                FetchDescriptor<AppMeta>(predicate: #Predicate {
                    !$0.isSoftDeleted && $0.key == key
                })
            ).first
        )
        #expect(meta.value == CompatibilityWriteGate.currentVersionString)
        #expect(meta.value == "2.0.0")
    }

    @Test func 高版本库禁止账户更新并回滚内存改动() throws {
        let context = try makeContext()
        let account = Account(name: "未来账户", kind: .fund)
        context.insert(account)
        context.insert(AppMeta(key: CompatibilityWriteGate.key, value: "99.0.0"))
        try context.save()

        var draft = AccountDraft(account: account)
        draft.name = "不应写入"
        #expect(throws: CompatibilityWriteGateError.self) {
            try AccountService(context: context)
                .updateAccount(uuid: account.uuid, draft: draft)
        }
        #expect(account.name == "未来账户")
        #expect(account.kind == .fund)
    }

    @Test func 未知账户类型保持原串且只读() throws {
        let context = try makeContext()
        let account = Account(name: "未来账户", kind: .fund)
        account.kindRawValue = "futureKind"
        context.insert(account)
        try context.save()

        var draft = AccountDraft(account: account)
        draft.name = "不应写入"
        #expect(throws: AccountServiceError.self) {
            try AccountService(context: context)
                .updateAccount(uuid: account.uuid, draft: draft)
        }
        #expect(account.name == "未来账户")
        #expect(account.kindRawValue == "futureKind")
    }

    @Test func 非法版本标记停止写入() throws {
        let context = try makeContext()
        context.insert(AppMeta(key: CompatibilityWriteGate.key, value: "future"))
        try context.save()
        #expect(throws: CompatibilityWriteGateError.invalidStoredVersion("future")) {
            _ = try LedgerService(context: context)
                .createLedger(LedgerDraft(name: "不应创建"))
        }
        #expect(try context.fetchCount(FetchDescriptor<Ledger>()) == 0)
    }
}
