import Foundation
import SwiftData

/// 全 lightweight 迁移计划（数据库设计文档 13.1，禁 .custom stage）
enum ZanzanMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}
