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

    @Test func 迁移计划以V1为唯一版本() {
        #expect(ZanzanMigrationPlan.schemas.count == 1)
        #expect(SchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
    }

    @Test func SchemaV1登记全部15张表() {
        #expect(SchemaV1.models.count == 15)
    }
}
