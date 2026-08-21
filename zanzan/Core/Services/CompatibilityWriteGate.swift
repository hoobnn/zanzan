import Foundation
import SwiftData

/// 库版本写闸：旧版本 App 看到更高版本写入过的数据库时，所有业务写入统一只读。
enum CompatibilityWriteGate {
    static let key = "schemaVersion"
    static let currentVersion = ZanzanMigrationPlan.schemas.last!.versionIdentifier

    static var currentVersionString: String {
        "\(currentVersion.major).\(currentVersion.minor).\(currentVersion.patch)"
    }

    static func ensureCurrentAppCanWrite(in context: ModelContext) throws {
        let metas = try storedVersionMetas(in: context)
        let storedVersions = try parsedVersions(from: metas)
        if let required = storedVersions.max(), required > currentVersion {
            throw CompatibilityWriteGateError.requiresNewerApp(
                required: "\(required.major).\(required.minor).\(required.patch)"
            )
        }
    }

    static func prepareForWrite(in context: ModelContext) throws {
        let metas = try storedVersionMetas(in: context)
        let storedVersions = try parsedVersions(from: metas)
        if let required = storedVersions.max(), required > currentVersion {
            throw CompatibilityWriteGateError.requiresNewerApp(
                required: "\(required.major).\(required.minor).\(required.patch)"
            )
        }
        if metas.isEmpty {
            context.insert(AppMeta(key: key, value: currentVersionString))
        } else {
            for meta in metas where meta.value != currentVersionString {
                meta.value = currentVersionString
                meta.updatedAt = .now
            }
        }
    }

    private static func storedVersionMetas(in context: ModelContext) throws -> [AppMeta] {
        let key = key
        return try context.fetch(
            FetchDescriptor<AppMeta>(predicate: #Predicate {
                !$0.isSoftDeleted && $0.key == key
            })
        )
    }

    private static func parsedVersions(from metas: [AppMeta]) throws -> [Schema.Version] {
        try metas.map { meta in
            guard let version = version(from: meta.value) else {
                throw CompatibilityWriteGateError.invalidStoredVersion(meta.value)
            }
            return version
        }
    }

    static func version(from value: String) -> Schema.Version? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0 else {
            return nil
        }
        return Schema.Version(major, minor, patch)
    }
}

extension ModelContext {
    func zanzanSave() throws {
        do {
            try CompatibilityWriteGate.prepareForWrite(in: self)
            try save()
        } catch {
            rollback()
            throw error
        }
    }
}

enum CompatibilityWriteGateError: LocalizedError, Equatable {
    case requiresNewerApp(required: String)
    case invalidStoredVersion(String)

    var errorDescription: String? {
        switch self {
        case let .requiresNewerApp(required):
            ZanzanLocalization.string(
                "此数据库已由更高版本（\(required)）写入，当前版本仅可读取；请升级 App 后再操作"
            )
        case .invalidStoredVersion:
            ZanzanLocalization.string( "数据库版本标记异常，为避免损坏数据已停止写入")
        }
    }
}
