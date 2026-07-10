import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct CategoryCommandsTests {
    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    private func makeCategory(
        _ context: ModelContext, name: String, kind: TransactionKind = .expense, parentID: UUID? = nil
    ) throws -> StoredCategory {
        var draft = CategoryDraft()
        draft.name = name
        draft.kind = kind
        draft.parentID = parentID
        return try CategoryCommands(context: context).createCategory(draft)
    }

    @Test func 创建一级分类追加排序() throws {
        let context = try makeContext()
        let first = try makeCategory(context, name: "餐饮")
        let second = try makeCategory(context, name: "交通")
        #expect(first.sortOrder == 0)
        #expect(second.sortOrder == 1)
        #expect(first.isBuiltIn == false)
        #expect(first.ledgerID == nil)
    }

    @Test func 子分类排序独立于父层() throws {
        let context = try makeContext()
        let parent = try makeCategory(context, name: "餐饮")
        _ = try makeCategory(context, name: "交通")
        let child = try makeCategory(context, name: "早餐", parentID: parent.uuid)
        #expect(child.sortOrder == 0)
        #expect(child.parentID == parent.uuid)
    }

    @Test func 挂到子分类下被拒() throws {
        let context = try makeContext()
        let parent = try makeCategory(context, name: "餐饮")
        let child = try makeCategory(context, name: "早餐", parentID: parent.uuid)
        var draft = CategoryDraft()
        draft.name = "三级"
        draft.parentID = child.uuid
        #expect(throws: CategoryCommandError.self) {
            try CategoryCommands(context: context).createCategory(draft)
        }
    }

    @Test func 父子方向不一致被拒() throws {
        let context = try makeContext()
        let parent = try makeCategory(context, name: "工资", kind: .income)
        var draft = CategoryDraft()
        draft.name = "餐补"
        draft.kind = .expense
        draft.parentID = parent.uuid
        #expect(throws: CategoryCommandError.self) {
            try CategoryCommands(context: context).createCategory(draft)
        }
    }

    @Test func 更新改名保方向() throws {
        let context = try makeContext()
        let category = try makeCategory(context, name: "餐饮")
        var draft = CategoryDraft(category: category)
        draft.name = "吃喝"
        try CategoryCommands(context: context).updateCategory(uuid: category.uuid, draft: draft)
        #expect(category.name == "吃喝")
    }

    @Test func 更新改方向被拒() throws {
        let context = try makeContext()
        let category = try makeCategory(context, name: "餐饮")
        var draft = CategoryDraft(category: category)
        draft.kind = .income
        #expect(throws: CategoryCommandError.self) {
            try CategoryCommands(context: context).updateCategory(uuid: category.uuid, draft: draft)
        }
    }

    @Test func 更新可移动到新父类() throws {
        let context = try makeContext()
        let oldParent = try makeCategory(context, name: "餐饮")
        let newParent = try makeCategory(context, name: "购物")
        let child = try makeCategory(context, name: "零食", parentID: oldParent.uuid)
        var draft = CategoryDraft(category: child)
        draft.parentID = newParent.uuid
        try CategoryCommands(context: context).updateCategory(uuid: child.uuid, draft: draft)
        #expect(child.parentID == newParent.uuid)
    }

    @Test func 带子分类的父类不得降为子类() throws {
        let context = try makeContext()
        let parent = try makeCategory(context, name: "餐饮")
        _ = try makeCategory(context, name: "早餐", parentID: parent.uuid)
        let other = try makeCategory(context, name: "购物")
        var draft = CategoryDraft(category: parent)
        draft.parentID = other.uuid
        #expect(throws: CategoryCommandError.self) {
            try CategoryCommands(context: context).updateCategory(uuid: parent.uuid, draft: draft)
        }
    }

    // MARK: - 归档 / 软删 / 恢复默认

    @Test func 归档与取消归档() throws {
        let context = try makeContext()
        let category = try makeCategory(context, name: "餐饮")
        let commands = CategoryCommands(context: context)
        try commands.setArchived(uuid: category.uuid, isArchived: true)
        #expect(category.isArchived)
        try commands.setArchived(uuid: category.uuid, isArchived: false)
        #expect(!category.isArchived)
    }

    @Test func 软删无引用分类() throws {
        let context = try makeContext()
        let category = try makeCategory(context, name: "餐饮")
        try CategoryCommands(context: context).softDeleteCategory(uuid: category.uuid)
        #expect(category.isSoftDeleted)
    }

    @Test func 有活跃流水的分类软删被阻断() throws {
        let context = try makeContext()
        try DefaultDataSeeder(context: context).seedIfNeeded()
        let ledger = try context.fetch(FetchDescriptor<StoredLedger>()).first!
        let account = try context.fetch(FetchDescriptor<StoredAccount>()).first!
        let category = try makeCategory(context, name: "测试分类")
        var draft = TransactionDraft()
        draft.kind = .expense
        draft.amountString = "10"
        draft.accountUUID = account.uuid
        draft.categoryUUID = category.uuid
        try TransactionCommands(context: context).recordTransaction(draft, ledgerID: ledger.uuid)
        #expect(throws: CategoryCommandError.self) {
            try CategoryCommands(context: context).softDeleteCategory(uuid: category.uuid)
        }
    }

    @Test func 有活跃子分类的父类软删被阻断() throws {
        let context = try makeContext()
        let parent = try makeCategory(context, name: "餐饮")
        _ = try makeCategory(context, name: "早餐", parentID: parent.uuid)
        #expect(throws: CategoryCommandError.self) {
            try CategoryCommands(context: context).softDeleteCategory(uuid: parent.uuid)
        }
    }

    @Test func 子分类软删后父类可删() throws {
        let context = try makeContext()
        let parent = try makeCategory(context, name: "餐饮")
        let child = try makeCategory(context, name: "早餐", parentID: parent.uuid)
        let commands = CategoryCommands(context: context)
        try commands.softDeleteCategory(uuid: child.uuid)
        try commands.softDeleteCategory(uuid: parent.uuid)
        #expect(parent.isSoftDeleted)
    }

    @Test func 恢复默认分类复位内置标记() throws {
        let context = try makeContext()
        try DefaultDataSeeder(context: context).seedIfNeeded()
        let commands = CategoryCommands(context: context)
        let builtIn = try context.fetch(
            FetchDescriptor<StoredCategory>(predicate: #Predicate { $0.isBuiltIn && $0.parentID == nil })
        ).first!
        let custom = try makeCategory(context, name: "自定义")
        try commands.setArchived(uuid: builtIn.uuid, isArchived: true)
        try commands.setArchived(uuid: custom.uuid, isArchived: true)
        // 内置子分类无流水引用，直接软删模拟历史删除
        let builtInChild = try context.fetch(
            FetchDescriptor<StoredCategory>(predicate: #Predicate { $0.isBuiltIn && $0.parentID != nil })
        ).first!
        try commands.softDeleteCategory(uuid: builtInChild.uuid)

        try commands.restoreDefaultCategories()

        #expect(!builtIn.isArchived)
        #expect(!builtInChild.isSoftDeleted)
        #expect(custom.isArchived) // 自定义分类不受影响
    }

    @Test func 自身为父被拒() throws {
        let context = try makeContext()
        let category = try makeCategory(context, name: "餐饮")
        var draft = CategoryDraft(category: category)
        draft.parentID = category.uuid
        #expect(throws: CategoryCommandError.self) {
            try CategoryCommands(context: context).updateCategory(uuid: category.uuid, draft: draft)
        }
    }
}
