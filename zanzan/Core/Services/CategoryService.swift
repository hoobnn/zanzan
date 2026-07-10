import Foundation
import SwiftData

/// 分类写路径命令（设计文档 5.3 / §4 软删语义）。不变量：两级树（禁三级）、
/// 父子方向一致、kind 终生不可改、ledgerID 本切片恒 nil（账本专属分类暂缓）。
struct CategoryService {
    let context: ModelContext

    @discardableResult
    func createCategory(_ draft: CategoryDraft) throws -> Category {
        let v = try draft.validated()
        try validateParent(v, movingCategoryUUID: nil)
        let category = Category(name: v.name, kind: v.kind, sortOrder: try siblingCount(of: v))
        category.parentID = v.parentID
        category.iconKindRawValue = IconDescriptor.Kind.symbol.rawValue
        category.iconPrimary = v.iconPrimary
        context.insert(category)
        try context.save()
        return category
    }

    func updateCategory(uuid: UUID, draft: CategoryDraft) throws {
        let category = try fetchActiveCategory(uuid)
        guard category.kind == draft.kind else { throw CategoryServiceError.kindImmutable }
        let v = try draft.validated()
        guard v.parentID != uuid else { throw CategoryServiceError.selfParent }
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

    /// 同层重排：按传入顺序重写 sortOrder。要求全部条目活跃且同 (parentID, kind) 层。
    func reorderCategories(orderedUUIDs: [UUID]) throws {
        let categories = try orderedUUIDs.map(fetchActiveCategory)
        guard let first = categories.first else { return }
        let isSameScope = categories.allSatisfy {
            $0.parentID == first.parentID && $0.kindRawValue == first.kindRawValue
        }
        guard isSameScope else { throw CategoryServiceError.reorderScopeMismatch }
        for (index, category) in categories.enumerated() where category.sortOrder != index {
            category.sortOrder = index
            category.updatedAt = .now
        }
        try context.save()
    }

    func setArchived(uuid: UUID, isArchived: Bool) throws {
        let category = try fetchActiveCategory(uuid)
        category.isArchived = isArchived
        category.updatedAt = .now
        try context.save()
    }

    /// 软删：活跃流水引用或活跃子分类存在都阻断并引导归档（设计文档 §4）。
    func softDeleteCategory(uuid: UUID) throws {
        let category = try fetchActiveCategory(uuid)
        let referenceCount = try context.fetchCount(
            FetchDescriptor<Transaction>(predicate: #Predicate {
                !$0.isSoftDeleted && $0.category?.uuid == uuid
            })
        )
        guard referenceCount == 0 else { throw CategoryServiceError.hasActiveTransactions }
        guard try activeChildCount(of: uuid) == 0 else { throw CategoryServiceError.hasActiveChildren }
        category.isSoftDeleted = true
        category.updatedAt = .now
        try context.save()
    }

    /// 恢复默认分类：对全部内置分类复位归档/软删标记（isBuiltIn 即识别机制，
    /// 全库无硬删除故内置行永不缺失；用户改名/改图标不回滚）。
    func restoreDefaultCategories() throws {
        let builtIns = try context.fetch(
            FetchDescriptor<Category>(predicate: #Predicate { $0.isBuiltIn })
        )
        for category in builtIns where category.isArchived || category.isSoftDeleted {
            category.isArchived = false
            category.isSoftDeleted = false
            category.updatedAt = .now
        }
        try context.save()
    }

    // MARK: - 私有

    /// 父分类校验：存在且活跃、自身是一级（禁三级）、方向一致；
    /// 移动场景另查自身无活跃子分类（带子分类降为子类同样产生三级）。
    private func validateParent(_ v: CategoryDraft.Validated, movingCategoryUUID: UUID?) throws {
        if let movingUUID = movingCategoryUUID, v.parentID != nil {
            guard try activeChildCount(of: movingUUID) == 0 else {
                throw CategoryServiceError.wouldCreateThirdLevel
            }
        }
        guard let parentID = v.parentID else { return }
        guard let parent = try? fetchActiveCategory(parentID) else {
            throw CategoryServiceError.parentNotFound
        }
        guard parent.parentID == nil else { throw CategoryServiceError.parentIsSubcategory }
        guard parent.kind == v.kind else { throw CategoryServiceError.parentKindMismatch }
    }

    private func siblingCount(of v: CategoryDraft.Validated) throws -> Int {
        let parentID = v.parentID
        let kindRaw = v.kind.rawValue
        return try context.fetchCount(
            FetchDescriptor<Category>(predicate: #Predicate {
                !$0.isSoftDeleted && $0.parentID == parentID && $0.kindRawValue == kindRaw
            })
        )
    }

    private func activeChildCount(of uuid: UUID) throws -> Int {
        try context.fetchCount(
            FetchDescriptor<Category>(predicate: #Predicate {
                !$0.isSoftDeleted && $0.parentID == uuid
            })
        )
    }

    private func fetchActiveCategory(_ uuid: UUID) throws -> Category {
        let descriptor = FetchDescriptor<Category>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        )
        guard let category = try context.fetch(descriptor).first else {
            throw CategoryServiceError.categoryNotFound
        }
        return category
    }
}

enum CategoryServiceError: LocalizedError {
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
        case .categoryNotFound: String(localized: "分类不存在或已删除")
        case .parentNotFound: String(localized: "父分类不存在或已删除")
        case .parentIsSubcategory: String(localized: "只支持两级分类，子分类下不能再建分类")
        case .parentKindMismatch: String(localized: "父分类方向与本分类不一致")
        case .kindImmutable: String(localized: "分类方向创建后不可修改")
        case .wouldCreateThirdLevel: String(localized: "该分类下还有子分类，不能移动为子分类")
        case .selfParent: String(localized: "不能把分类挂到自己名下")
        case .hasActiveTransactions: String(localized: "分类名下还有流水，无法删除；可先归档或转移流水")
        case .hasActiveChildren: String(localized: "请先处理全部子分类，再删除父分类")
        case .reorderScopeMismatch: String(localized: "排序列表必须是同一层级、同一方向的分类")
        }
    }
}
