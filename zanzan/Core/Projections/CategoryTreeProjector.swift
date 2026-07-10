import Foundation
import SwiftData

/// 分类树只读投影（设计文档 5.3）：一次取回单方向活跃分类，内存拼两级树。
/// 「归档父连带子不可选」的读路径口径在此落地，命令层不级联。
struct CategoryTreeNode {
    let category: StoredCategory
    let children: [StoredCategory]
}

struct CategoryTreeProjector {
    let context: ModelContext

    /// includeArchived=true → 管理列表；false → 记账可选树（归档连带剔除）。
    func tree(kind: TransactionKind, includeArchived: Bool) throws -> [CategoryTreeNode] {
        let kindRaw = kind.rawValue
        let categories = try context.fetch(
            FetchDescriptor<StoredCategory>(
                predicate: #Predicate { !$0.isSoftDeleted && $0.kindRawValue == kindRaw },
                sortBy: [SortDescriptor(\.sortOrder)]
            )
        )
        let childrenByParent = Dictionary(grouping: categories.filter { $0.parentID != nil }) { $0.parentID! }
        return categories
            .filter { $0.parentID == nil && (includeArchived || !$0.isArchived) }
            .map { parent in
                let children = (childrenByParent[parent.uuid] ?? [])
                    .filter { includeArchived || !$0.isArchived }
                return CategoryTreeNode(category: parent, children: children)
            }
    }
}
