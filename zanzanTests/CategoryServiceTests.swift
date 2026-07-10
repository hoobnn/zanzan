import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct CategoryServiceTests {
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
        #expect(throws: CategoryServiceError.self) {
            try CategoryService(context: context).createCategory(draft)
        }
    }

    @Test func 父子方向不一致被拒() throws {
        let context = try makeContext()
        let parent = try makeCategory(context, name: "工资", kind: .income)
        var draft = CategoryDraft()
        draft.name = "餐补"
        draft.kind = .expense
        draft.parentID = parent.uuid
        #expect(throws: CategoryServiceError.self) {
            try CategoryService(context: context).createCategory(draft)
        }
    }

    @Test func 更新改名保方向() throws {
        let context = try makeContext()
        let category = try makeCategory(context, name: "餐饮")
        var draft = CategoryDraft(category: category)
        draft.name = "吃喝"
        try CategoryService(context: context).updateCategory(uuid: category.uuid, draft: draft)
        #expect(category.name == "吃喝")
    }

    @Test func 更新改方向被拒() throws {
        let context = try makeContext()
        let category = try makeCategory(context, name: "餐饮")
        var draft = CategoryDraft(category: category)
        draft.kind = .income
        #expect(throws: CategoryServiceError.self) {
            try CategoryService(context: context).updateCategory(uuid: category.uuid, draft: draft)
        }
    }

    @Test func 更新可移动到新父类() throws {
        let context = try makeContext()
        let oldParent = try makeCategory(context, name: "餐饮")
        let newParent = try makeCategory(context, name: "购物")
        let child = try makeCategory(context, name: "零食", parentID: oldParent.uuid)
        var draft = CategoryDraft(category: child)
        draft.parentID = newParent.uuid
        try CategoryService(context: context).updateCategory(uuid: child.uuid, draft: draft)
        #expect(child.parentID == newParent.uuid)
    }

    @Test func 带子分类的父类不得降为子类() throws {
        let context = try makeContext()
        let parent = try makeCategory(context, name: "餐饮")
        _ = try makeCategory(context, name: "早餐", parentID: parent.uuid)
        let other = try makeCategory(context, name: "购物")
        var draft = CategoryDraft(category: parent)
        draft.parentID = other.uuid
        #expect(throws: CategoryServiceError.self) {
            try CategoryService(context: context).updateCategory(uuid: parent.uuid, draft: draft)
        }
    }

    // MARK: - 排序

    @Test func 同层重排按传入顺序写入() throws {
        let context = try makeContext()
        let a = try makeCategory(context, name: "餐饮")
        let b = try makeCategory(context, name: "交通")
        let c = try makeCategory(context, name: "购物")
        try CategoryService(context: context).reorderCategories(orderedUUIDs: [c.uuid, a.uuid, b.uuid])
        #expect(c.sortOrder == 0)
        #expect(a.sortOrder == 1)
        #expect(b.sortOrder == 2)
    }

    @Test func 跨层混排被拒() throws {
        let context = try makeContext()
        let parent = try makeCategory(context, name: "餐饮")
        let child = try makeCategory(context, name: "早餐", parentID: parent.uuid)
        #expect(throws: CategoryServiceError.self) {
            try CategoryService(context: context).reorderCategories(orderedUUIDs: [parent.uuid, child.uuid])
        }
    }

    @Test func 跨方向混排被拒() throws {
        let context = try makeContext()
        let expense = try makeCategory(context, name: "餐饮")
        let income = try makeCategory(context, name: "工资", kind: .income)
        #expect(throws: CategoryServiceError.self) {
            try CategoryService(context: context).reorderCategories(orderedUUIDs: [income.uuid, expense.uuid])
        }
    }

    // MARK: - 归档 / 软删 / 恢复默认

    @Test func 归档与取消归档() throws {
        let context = try makeContext()
        let category = try makeCategory(context, name: "餐饮")
        let commands = CategoryService(context: context)
        try commands.setArchived(uuid: category.uuid, isArchived: true)
        #expect(category.isArchived)
        try commands.setArchived(uuid: category.uuid, isArchived: false)
        #expect(!category.isArchived)
    }

    @Test func 软删无引用分类() throws {
        let context = try makeContext()
        let category = try makeCategory(context, name: "餐饮")
        try CategoryService(context: context).softDeleteCategory(uuid: category.uuid)
        #expect(category.isSoftDeleted)
    }

    @Test func 有活跃流水的分类软删被阻断() throws {
        let context = try makeContext()
        try DefaultDataSeeder(context: context).seedIfNeeded()
        let ledger = try context.fetch(FetchDescriptor<Ledger>()).first!
        let account = try context.fetch(FetchDescriptor<Account>()).first!
        let category = try makeCategory(context, name: "测试分类")
        var draft = TransactionDraft()
        draft.kind = .expense
        draft.amountString = "10"
        draft.accountUUID = account.uuid
        draft.categoryUUID = category.uuid
        try TransactionService(context: context).recordTransaction(draft, ledgerID: ledger.uuid)
        #expect(throws: CategoryServiceError.self) {
            try CategoryService(context: context).softDeleteCategory(uuid: category.uuid)
        }
    }

    @Test func 有活跃子分类的父类软删被阻断() throws {
        let context = try makeContext()
        let parent = try makeCategory(context, name: "餐饮")
        _ = try makeCategory(context, name: "早餐", parentID: parent.uuid)
        #expect(throws: CategoryServiceError.self) {
            try CategoryService(context: context).softDeleteCategory(uuid: parent.uuid)
        }
    }

    @Test func 子分类软删后父类可删() throws {
        let context = try makeContext()
        let parent = try makeCategory(context, name: "餐饮")
        let child = try makeCategory(context, name: "早餐", parentID: parent.uuid)
        let commands = CategoryService(context: context)
        try commands.softDeleteCategory(uuid: child.uuid)
        try commands.softDeleteCategory(uuid: parent.uuid)
        #expect(parent.isSoftDeleted)
    }

    @Test func 恢复默认分类复位内置标记() throws {
        let context = try makeContext()
        try DefaultDataSeeder(context: context).seedIfNeeded()
        let commands = CategoryService(context: context)
        let builtIn = try context.fetch(
            FetchDescriptor<Category>(predicate: #Predicate { $0.isBuiltIn && $0.parentID == nil })
        ).first!
        let custom = try makeCategory(context, name: "自定义")
        try commands.setArchived(uuid: builtIn.uuid, isArchived: true)
        try commands.setArchived(uuid: custom.uuid, isArchived: true)
        // 内置子分类无流水引用，直接软删模拟历史删除
        let builtInChild = try context.fetch(
            FetchDescriptor<Category>(predicate: #Predicate { $0.isBuiltIn && $0.parentID != nil })
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
        #expect(throws: CategoryServiceError.self) {
            try CategoryService(context: context).updateCategory(uuid: category.uuid, draft: draft)
        }
    }

    // MARK: - 软删引用检查 / 撤销恢复

    @Test func 有周期规则引用阻断删除() throws {
        let context = try makeContext()
        let category = try makeCategory(context, name: "餐饮")
        let rule = RecurringRule(
            name: "房租", frequency: .monthly, startAt: .now, nextRunAt: .now,
            templateKind: .expense, templateAmountMinorUnits: 100
        )
        rule.templateCategoryID = category.uuid
        context.insert(rule)
        try context.save()
        #expect(throws: CategoryServiceError.self) {
            try CategoryService(context: context).softDeleteCategory(uuid: category.uuid)
        }
    }

    @Test func 删除分类级联软删其预算行() throws {
        let context = try makeContext()
        let category = try makeCategory(context, name: "餐饮")
        let ledgerID = UUID()
        let template = Budget(ledgerID: ledgerID, amountMinorUnits: 100_000)
        template.categoryID = category.uuid
        let monthly = Budget(ledgerID: ledgerID, amountMinorUnits: 100_000)
        monthly.categoryID = category.uuid
        monthly.periodYear = 2_026
        monthly.periodMonth = 7
        context.insert(template)
        context.insert(monthly)
        try context.save()
        try CategoryService(context: context).softDeleteCategory(uuid: category.uuid)
        #expect(category.isSoftDeleted)
        #expect(template.isSoftDeleted)
        #expect(monthly.isSoftDeleted)
    }

    @Test func 撤销软删恢复分类并级联恢复预算行() throws {
        let context = try makeContext()
        let commands = CategoryService(context: context)
        let category = try makeCategory(context, name: "餐饮")
        let ledger = try LedgerService(context: context).createLedger(LedgerDraft(name: "日常"))
        let budget = Budget(ledgerID: ledger.uuid, amountMinorUnits: 100_000)
        budget.categoryID = category.uuid
        context.insert(budget)
        try context.save()
        try commands.softDeleteCategory(uuid: category.uuid)
        try commands.undoSoftDeleteCategory(uuid: category.uuid)
        #expect(!category.isSoftDeleted)
        #expect(!budget.isSoftDeleted)
    }

    @Test func 父分类已删时恢复子分类被阻断() throws {
        let context = try makeContext()
        let commands = CategoryService(context: context)
        let parent = try makeCategory(context, name: "餐饮")
        let child = try makeCategory(context, name: "早餐", parentID: parent.uuid)
        try commands.softDeleteCategory(uuid: child.uuid)
        try commands.softDeleteCategory(uuid: parent.uuid)
        #expect(throws: CategoryServiceError.self) {
            try commands.undoSoftDeleteCategory(uuid: child.uuid)
        }
        #expect(child.isSoftDeleted)
    }

    @Test func 双重恢复幂等() throws {
        let context = try makeContext()
        let commands = CategoryService(context: context)
        let category = try makeCategory(context, name: "餐饮")
        try commands.softDeleteCategory(uuid: category.uuid)
        try commands.undoSoftDeleteCategory(uuid: category.uuid)
        try commands.undoSoftDeleteCategory(uuid: category.uuid)
        #expect(!category.isSoftDeleted)
    }

    // MARK: - 恢复默认分类的父指针修复

    @Test func 恢复默认分类重挂种子默认父类() throws {
        let context = try makeContext()
        try DefaultDataSeeder(context: context).seedIfNeeded()
        let breakfastName = String(localized: "早餐")
        let breakfast = try context.fetch(
            FetchDescriptor<Category>(predicate: #Predicate { $0.isBuiltIn && $0.name == breakfastName })
        ).first!
        // 模拟历史坏数据：曾被挂到用户分类下、该分类又被删（parentID 悬空）
        breakfast.parentID = UUID()
        breakfast.isSoftDeleted = true
        try context.save()
        try CategoryService(context: context).restoreDefaultCategories()
        let diningName = String(localized: "餐饮")
        let dining = try context.fetch(
            FetchDescriptor<Category>(predicate: #Predicate {
                $0.isBuiltIn && $0.name == diningName && $0.parentID == nil
            })
        ).first!
        #expect(!breakfast.isSoftDeleted)
        #expect(breakfast.parentID == dining.uuid)
    }

    @Test func 恢复默认分类定不到默认父类升为顶级() throws {
        let context = try makeContext()
        try DefaultDataSeeder(context: context).seedIfNeeded()
        let breakfastName = String(localized: "早餐")
        let breakfast = try context.fetch(
            FetchDescriptor<Category>(predicate: #Predicate { $0.isBuiltIn && $0.name == breakfastName })
        ).first!
        breakfast.name = "用户改过名" // 改名后种子树定位不到默认父类
        breakfast.parentID = UUID()
        breakfast.isSoftDeleted = true
        try context.save()
        try CategoryService(context: context).restoreDefaultCategories()
        #expect(!breakfast.isSoftDeleted)
        #expect(breakfast.parentID == nil)
    }
}
