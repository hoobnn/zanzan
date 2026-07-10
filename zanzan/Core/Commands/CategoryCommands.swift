import Foundation
import SwiftData

/// 分类写路径命令（设计文档 5.3 / §4 软删语义）。不变量：两级树（禁三级）、
/// 父子方向一致、kind 终生不可改、ledgerID 本切片恒 nil（账本专属分类暂缓）。
struct CategoryCommands {
    let context: ModelContext

    @discardableResult
    func createCategory(_ draft: CategoryDraft) throws -> StoredCategory {
        let v = try draft.validated()
        try validateParent(v, movingCategoryUUID: nil)
        let category = StoredCategory(name: v.name, kind: v.kind, sortOrder: try siblingCount(of: v))
        category.parentID = v.parentID
        category.iconKindRawValue = StoredIconDescriptor.Kind.symbol.rawValue
        category.iconPrimary = v.iconPrimary
        context.insert(category)
        try context.save()
        return category
    }

    func updateCategory(uuid: UUID, draft: CategoryDraft) throws {
        let category = try fetchActiveCategory(uuid)
        guard category.kind == draft.kind else { throw CategoryCommandError.kindImmutable }
        let v = try draft.validated()
        guard v.parentID != uuid else { throw CategoryCommandError.selfParent }
        if v.parentID != category.parentID {
            try validateParent(v, movingCategoryUUID: uuid)
            category.parentID = v.parentID
            category.sortOrder = try siblingCount(of: v)
        }
        category.name = v.name
        category.iconPrimary = v.iconPrimary
        category.updatedAt = .now
        try context.save()
    }

    // MARK: - 私有

    /// 父分类校验：存在且活跃、自身是一级（禁三级）、方向一致；
    /// 移动场景另查自身无活跃子分类（带子分类降为子类同样产生三级）。
    private func validateParent(_ v: CategoryDraft.Validated, movingCategoryUUID: UUID?) throws {
        if let movingUUID = movingCategoryUUID, v.parentID != nil {
            guard try activeChildCount(of: movingUUID) == 0 else {
                throw CategoryCommandError.wouldCreateThirdLevel
            }
        }
        guard let parentID = v.parentID else { return }
        guard let parent = try? fetchActiveCategory(parentID) else {
            throw CategoryCommandError.parentNotFound
        }
        guard parent.parentID == nil else { throw CategoryCommandError.parentIsSubcategory }
        guard parent.kind == v.kind else { throw CategoryCommandError.parentKindMismatch }
    }

    private func siblingCount(of v: CategoryDraft.Validated) throws -> Int {
        let parentID = v.parentID
        let kindRaw = v.kind.rawValue
        return try context.fetchCount(
            FetchDescriptor<StoredCategory>(predicate: #Predicate {
                !$0.isSoftDeleted && $0.parentID == parentID && $0.kindRawValue == kindRaw
            })
        )
    }

    private func activeChildCount(of uuid: UUID) throws -> Int {
        try context.fetchCount(
            FetchDescriptor<StoredCategory>(predicate: #Predicate {
                !$0.isSoftDeleted && $0.parentID == uuid
            })
        )
    }

    private func fetchActiveCategory(_ uuid: UUID) throws -> StoredCategory {
        let descriptor = FetchDescriptor<StoredCategory>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        )
        guard let category = try context.fetch(descriptor).first else {
            throw CategoryCommandError.categoryNotFound
        }
        return category
    }
}

enum CategoryCommandError: LocalizedError {
    case categoryNotFound
    case parentNotFound
    case parentIsSubcategory
    case parentKindMismatch
    case kindImmutable
    case wouldCreateThirdLevel
    case selfParent
    case hasActiveTransactions
    case hasActiveChildren
    case reorderScopeMismatch

    var errorDescription: String? {
        switch self {
        case .categoryNotFound: "分类不存在或已删除"
        case .parentNotFound: "父分类不存在或已删除"
        case .parentIsSubcategory: "只支持两级分类，子分类下不能再建分类"
        case .parentKindMismatch: "父分类方向与本分类不一致"
        case .kindImmutable: "分类方向创建后不可修改"
        case .wouldCreateThirdLevel: "该分类下还有子分类，不能移动为子分类"
        case .selfParent: "不能把分类挂到自己名下"
        case .hasActiveTransactions: "分类名下还有流水，无法删除；可先归档或转移流水"
        case .hasActiveChildren: "请先处理全部子分类，再删除父分类"
        case .reorderScopeMismatch: "排序列表必须是同一层级、同一方向的分类"
        }
    }
}
