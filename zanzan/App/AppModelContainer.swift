import Foundation
import SwiftData

/// ModelContainer 装配唯一入口（App 与测试共用）。
/// CloudKit 暂关（.none）；开启时改此处配置并添加 iCloud entitlement。
enum AppModelContainer {
    static func make(inMemory: Bool = false, storeURL: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV2.self)
        let configuration = if let storeURL {
            ModelConfiguration(
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
        } else {
            ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: inMemory,
                cloudKitDatabase: .none
            )
        }
        return try ModelContainer(
            for: schema,
            migrationPlan: ZanzanMigrationPlan.self,
            configurations: configuration
        )
    }
}
