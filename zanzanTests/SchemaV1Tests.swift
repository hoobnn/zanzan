import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct SchemaV1Tests {
    @Test func 账本插入与读取往返() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let ledger = Ledger(name: "日常")
        context.insert(ledger)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Ledger>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.name == "日常")
        #expect(fetched.first?.isDefault == false)
        #expect(fetched.first?.isSoftDeleted == false)
        #expect(fetched.first?.colorID == "blue")
    }

    @Test func 迁移计划登记V1到V2轻量迁移() {
        #expect(ZanzanMigrationPlan.schemas.count == 2)
        #expect(ZanzanMigrationPlan.stages.count == 1)
        #expect(SchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        #expect(SchemaV2.versionIdentifier == Schema.Version(2, 0, 0))
    }

    @Test func V1与V2均登记全部15张表() {
        #expect(SchemaV1.models.count == 15)
        #expect(SchemaV2.models.count == 15)
    }

    @Test func V1实盘轻量迁移到V2保留旧期表且新字段取默认值() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "zanzan-v1-v2-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "migration.store")
        let planID = UUID()
        let accountID = UUID()
        let ledgerID = UUID()
        let dueAt = Date(timeIntervalSince1970: 1_786_000_000)

        do {
            let schema = Schema(versionedSchema: SchemaV1.self)
            let configuration = ModelConfiguration(
                "Migration",
                schema: schema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: configuration)
            let context = ModelContext(container)

            let oldPlan = SchemaV1.InstallmentPlan(
                name: "历史分期",
                kind: .purchase,
                accountID: accountID,
                ledgerID: ledgerID,
                principalMinorUnits: 10_000,
                totalPeriods: 3,
                amortizationKind: .flatFee,
                firstDueAt: dueAt
            )
            oldPlan.uuid = planID
            oldPlan.note = "V1"
            context.insert(oldPlan)
            context.insert(InstallmentPeriod(
                planID: planID,
                periodIndex: 1,
                dueAt: dueAt,
                principalMinorUnits: 3_333,
                interestMinorUnits: 100
            ))
            try context.save()
        }

        let schema = Schema(versionedSchema: SchemaV2.self)
        let configuration = ModelConfiguration(
            "Migration",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: schema,
            migrationPlan: ZanzanMigrationPlan.self,
            configurations: configuration
        )
        let context = ModelContext(container)

        let plan = try #require(try context.fetch(FetchDescriptor<InstallmentPlan>()).first)
        #expect(plan.uuid == planID)
        #expect(plan.name == "历史分期")
        #expect(plan.accountID == accountID)
        #expect(plan.ledgerID == ledgerID)
        #expect(plan.note == "V1")
        #expect(plan.totalChargeMinorUnits == nil)
        #expect(plan.chargeCollectionKind == .perPeriod)
        #expect(plan.principalRoundingKind == .downToMinorUnit)
        #expect(plan.principalRemainderKind == .lastPeriod)
        #expect(plan.chargeRoundingKind == .downToMinorUnit)
        #expect(plan.chargeRemainderKind == .lastPeriod)

        let period = try #require(try context.fetch(FetchDescriptor<InstallmentPeriod>()).first)
        #expect(period.planID == planID)
        #expect(period.periodIndex == 1)
        #expect(period.dueAt == dueAt)
        #expect(period.principalMinorUnits == 3_333)
        #expect(period.interestMinorUnits == 100)
        #expect(period.status == .pending)
    }
}
