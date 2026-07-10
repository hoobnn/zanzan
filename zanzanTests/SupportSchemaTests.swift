import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct SupportSchemaTests {
    @Test func 周期规则Codable数组往返() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let tagIDs = [UUID(), UUID()]
        let rule = RecurringRule(
            name: "房租",
            frequency: .monthly,
            startAt: .now,
            nextRunAt: .now,
            templateKind: .expense,
            templateAmountMinorUnits: 350_000
        )
        rule.recurrenceDays = [1, 15, 31]
        rule.templateTagIDs = tagIDs
        context.insert(rule)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<RecurringRule>()).first)
        #expect(fetched.frequency == .monthly)
        #expect(fetched.interval == 1)
        #expect(fetched.recurrenceDays == [1, 15, 31])
        #expect(fetched.templateTagIDs == tagIDs)
        #expect(fetched.templateKind == .expense)
        #expect(fetched.endAt == nil)
        #expect(!fetched.isPaused)
    }

    @Test func 导入批次往返() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let batch = ImportBatch(fileName: "alipay-2026-06.csv", importedAt: .now)
        batch.contentHash = "abc123"
        batch.transactionCount = 42
        context.insert(batch)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<ImportBatch>()).first)
        #expect(fetched.fileName == "alipay-2026-06.csv")
        #expect(fetched.contentHash == "abc123")
        #expect(fetched.transactionCount == 42)
    }

    @Test func 余额检查点含汇率快照往返() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let accountID = UUID()
        let snapshot = BalanceSnapshot(
            accountID: accountID, snapshotAt: .now, balanceMinorUnits: 123_456
        )
        snapshot.fxRateToBase = Decimal(string: "7.18")
        context.insert(snapshot)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<BalanceSnapshot>()).first)
        #expect(fetched.accountID == accountID)
        #expect(fetched.balanceMinorUnits == 123_456)
        #expect(fetched.fxRateToBase == Decimal(string: "7.18"))
    }

    @Test func 操作日志与元数据往返() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        context.insert(AuditLog(action: "accountDelete", detail: "招行卡"))
        context.insert(AppMeta(key: "schemaVersion", value: "1.0.0"))
        try context.save()

        let log = try #require(try context.fetch(FetchDescriptor<AuditLog>()).first)
        #expect(log.action == "accountDelete")
        #expect(log.detail == "招行卡")

        let meta = try #require(try context.fetch(FetchDescriptor<AppMeta>()).first)
        #expect(meta.key == "schemaVersion")
        #expect(meta.value == "1.0.0")
    }
}
