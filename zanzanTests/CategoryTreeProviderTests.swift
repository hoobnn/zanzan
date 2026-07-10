import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct CategoryTreeProviderTests {
    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    private func makeCategory(
        _ context: ModelContext, name: String, kind: TransactionKind = .expense, parentID: UUID? = nil
    ) throws -> Category {
        var draft = CategoryDraft()
        draft.name = name
        draft.kind = kind
        draft.parentID = parentID
        return try CategoryService(context: context).createCategory(draft)
    }

    @Test func 两级树按排序返回() throws {
        let context = try makeContext()
        let dining = try makeCategory(context, name: "餐饮")
        _ = try makeCategory(context, name: "交通")
        _ = try makeCategory(context, name: "午餐", parentID: dining.uuid)
        _ = try makeCategory(context, name: "早餐", parentID: dining.uuid)
        _ = try makeCategory(context, name: "工资", kind: .income)

        let tree = try CategoryTreeProvider(context: context).tree(kind: .expense, includeArchived: true)
        #expect(tree.map(\.category.name) == ["餐饮", "交通"])
        #expect(tree[0].children.map(\.name) == ["午餐", "早餐"])
        #expect(tree[1].children.isEmpty)
    }

    @Test func 记账树剔除归档子分类() throws {
        let context = try makeContext()
        let dining = try makeCategory(context, name: "餐饮")
        let breakfast = try makeCategory(context, name: "早餐", parentID: dining.uuid)
        try CategoryService(context: context).setArchived(uuid: breakfast.uuid, isArchived: true)

        let selectable = try CategoryTreeProvider(context: context).tree(kind: .expense, includeArchived: false)
        #expect(selectable[0].children.isEmpty)
        let manage = try CategoryTreeProvider(context: context).tree(kind: .expense, includeArchived: true)
        #expect(manage[0].children.map(\.name) == ["早餐"])
    }

    @Test func 归档父分类连带子分类剔除() throws {
        let context = try makeContext()
        let dining = try makeCategory(context, name: "餐饮")
        _ = try makeCategory(context, name: "早餐", parentID: dining.uuid)
        _ = try makeCategory(context, name: "交通")
        try CategoryService(context: context).setArchived(uuid: dining.uuid, isArchived: true)

        let selectable = try CategoryTreeProvider(context: context).tree(kind: .expense, includeArchived: false)
        #expect(selectable.map(\.category.name) == ["交通"])
    }

    @Test func 软删分类不出现在任何树() throws {
        let context = try makeContext()
        let dining = try makeCategory(context, name: "餐饮")
        try CategoryService(context: context).softDeleteCategory(uuid: dining.uuid)
        let manage = try CategoryTreeProvider(context: context).tree(kind: .expense, includeArchived: true)
        #expect(manage.isEmpty)
    }
}
