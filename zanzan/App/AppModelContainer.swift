import Foundation
import SwiftData

/// ModelContainer 装配唯一入口（App 与测试共用）。
/// CloudKit 暂关（.none）；开启时改此处配置并添加 iCloud entitlement。
enum AppModelContainer {
    static func make(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: ZanzanMigrationPlan.self,
            configurations: configuration
        )
    }
}
