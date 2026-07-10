# M1 逻辑层（分类管理 + 统计投影 + 明细筛选）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付功能路线图 M1 三条目的全部非 UI 逻辑：分类管理写路径（Draft + Commands）、分类树投影、月度统计投影（含二级 rollup）、明细筛选与日/月小计投影。

**Architecture:** 沿既有 Draft → Command → Projector 分层：`CategoryDraft` 入口校验，`CategoryCommands` 持有全部写不变量（两级树、方向锁定、软删阻断），`CategoryTreeProjector` / `MonthlyStatsProjector` / `TransactionListProjection` 为只读投影。统计口径（报销剔除、fee 计支出）收敛到 `StoredTransaction` 扩展供两处投影共用。

**Tech Stack:** Swift / SwiftData / Swift Testing（`@Test` + `#expect` + 内存容器）。

## Global Constraints

- 金额一律整数最小货币单位（分），禁止浮点金额路径。
- schema 不动：只新增 Draft/Commands/Projections 文件，不改任何 `Stored*` 的存储属性。
- 全库无硬删除；归档 = 停用（历史统计照常），软删 = 隐藏（可撤销）。
- 查询下推：本表标量过滤（isSoftDeleted / ledgerID / occurredAt 窗口 / isExcludedFromStats）一律进 `#Predicate`；内存层只做关系穿越与聚合（数据库设计文档 §4「查询下推」）。
- 命令写路径统一维护 `updatedAt`；读路径对未知枚举返回 nil 且不回写。
- 工程为 fileSystemSynchronizedGroups，新文件放对目录即入 target，无需改 pbxproj。
- 测试文件命名 `<Subject>Tests.swift`，`@MainActor struct`，容器 `AppModelContainer.make(inMemory: true)`，测试名用中文描述行为。
- 提交标题 `<emoji> <type>(<scope>): <subject>`（scope 小写，≤72 字符），正文末尾加：
  ```
  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
  🤖 Generated with Claude Code
  ```
- 单任务测试命令模板（下文简称 `TEST <名>`）：
  ```bash
  xcodebuild test -project zanzan.xcodeproj -scheme zanzan \
    -only-testing:zanzanTests/<名> \
    -destination 'platform=iOS Simulator,name=iPhone 17' -quiet
  ```

---

### Task 1: CategoryDraft — 分类草稿校验

**Files:**
- Create: `zanzan/Core/Drafts/CategoryDraft.swift`
- Test: `zanzanTests/CategoryDraftTests.swift`

**Interfaces:**
- Consumes: `TransactionKind`（已有枚举，expense/income/transfer）、`StoredCategory`（回填 init）。
- Produces: `CategoryDraft`（`name: String`, `kind: TransactionKind`, `parentID: UUID?`, `iconPrimary: String`）、`CategoryDraft.Validated`（同名字段，name/icon 已 trim）、`init(category: StoredCategory)` 回填、`CategoryDraftError`（`emptyName` / `invalidKind`）。Task 2 的 Commands 消费 `validated()`。

- [ ] **Step 1: 写失败测试**

```swift
import Foundation
import Testing
@testable import zanzan

struct CategoryDraftTests {
    @Test func 合法草稿通过并归一化() throws {
        var draft = CategoryDraft()
        draft.name = "  奶茶 "
        draft.kind = .expense
        draft.iconPrimary = " cup.and.saucer "
        let v = try draft.validated()
        #expect(v.name == "奶茶")
        #expect(v.kind == .expense)
        #expect(v.iconPrimary == "cup.and.saucer")
        #expect(v.parentID == nil)
    }

    @Test func 空名被拒() {
        var draft = CategoryDraft()
        draft.name = "  "
        #expect(throws: CategoryDraftError.self) { _ = try draft.validated() }
    }

    @Test func 转账方向被拒() {
        var draft = CategoryDraft()
        draft.name = "非法"
        draft.kind = .transfer
        #expect(throws: CategoryDraftError.self) { _ = try draft.validated() }
    }

    @Test func 图标为空回退默认() throws {
        var draft = CategoryDraft()
        draft.name = "杂项"
        let v = try draft.validated()
        #expect(v.iconPrimary == "tag")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `TEST CategoryDraftTests`
Expected: 编译失败 "cannot find 'CategoryDraft' in scope"

- [ ] **Step 3: 最小实现**

```swift
import Foundation

/// 分类表单草稿——入口校验 + 归一化（设计文档 5.3）。
/// 方向仅 expense/income 合法；parentID 存在性/层级校验属命令层（需查库）。
struct CategoryDraft {
    var name: String = ""
    var kind: TransactionKind = .expense
    var parentID: UUID? = nil
    var iconPrimary: String = ""

    struct Validated {
        let name: String
        let kind: TransactionKind
        let parentID: UUID?
        let iconPrimary: String
    }

    func validated() throws -> Validated {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CategoryDraftError.emptyName }
        guard kind != .transfer else { throw CategoryDraftError.invalidKind }
        let icon = iconPrimary.trimmingCharacters(in: .whitespaces)
        return Validated(
            name: name,
            kind: kind,
            parentID: parentID,
            iconPrimary: icon.isEmpty ? "tag" : icon
        )
    }
}

extension CategoryDraft {
    /// 编辑表单回填。
    init(category: StoredCategory) {
        self.init()
        name = category.name
        kind = category.kind ?? .expense
        parentID = category.parentID
        iconPrimary = category.iconPrimary
    }
}

enum CategoryDraftError: LocalizedError {
    case emptyName
    case invalidKind

    var errorDescription: String? {
        switch self {
        case .emptyName: "分类名不能为空"
        case .invalidKind: "分类方向只能是支出或收入"
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `TEST CategoryDraftTests`
Expected: PASS（4 tests）

- [ ] **Step 5: 提交**

```bash
git add zanzan/Core/Drafts/CategoryDraft.swift zanzanTests/CategoryDraftTests.swift
git commit -m "✨ feat(categories): 分类草稿校验与回填"
```
（正文带署名两行，下同，不再重复。）

---

### Task 2: CategoryCommands — 创建与更新

**Files:**
- Create: `zanzan/Core/Commands/CategoryCommands.swift`
- Test: `zanzanTests/CategoryCommandsTests.swift`

**Interfaces:**
- Consumes: `CategoryDraft.validated()`（Task 1）、`StoredCategory`、`StoredTransaction`。
- Produces:
  - `struct CategoryCommands { let context: ModelContext }`
  - `@discardableResult func createCategory(_ draft: CategoryDraft) throws -> StoredCategory`
  - `func updateCategory(uuid: UUID, draft: CategoryDraft) throws`
  - `enum CategoryCommandError: LocalizedError`，本任务用到 `categoryNotFound` / `parentNotFound` / `parentIsSubcategory` / `parentKindMismatch` / `kindImmutable` / `wouldCreateThirdLevel` / `selfParent`。

**不变量（设计文档 5.3 + §4）：**
- 两级树：父分类必须活跃且自身无 `parentID`（禁三级）；带活跃子分类的分类不得再挂到别的父下（同样禁三级）；不得以自身为父。
- 方向：父子 `kind` 必须一致；分类 `kind` 创建后终生不可改（历史流水方向匹配依赖它）。
- `sortOrder` 追加：同 kind 同 parent 层内活跃分类计数。
- `ledgerID` 本切片恒 nil（路线图：账本专属分类暂缓）。

- [ ] **Step 1: 写失败测试**

```swift
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `TEST CategoryCommandsTests`
Expected: 编译失败 "cannot find 'CategoryCommands' in scope"

- [ ] **Step 3: 最小实现**

```swift
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
```

（`hasActiveTransactions` / `hasActiveChildren` / `reorderScopeMismatch` 为 Task 3/4 预留 case，避免枚举文件反复动。）

- [ ] **Step 4: 跑测试确认通过**

Run: `TEST CategoryCommandsTests`
Expected: PASS（9 tests）

- [ ] **Step 5: 提交**

```bash
git add zanzan/Core/Commands/CategoryCommands.swift zanzanTests/CategoryCommandsTests.swift
git commit -m "✨ feat(categories): 分类创建与更新命令（两级树不变量）"
```

---

### Task 3: CategoryCommands — 归档 / 软删 / 恢复默认

**Files:**
- Modify: `zanzan/Core/Commands/CategoryCommands.swift`（追加三个方法）
- Test: `zanzanTests/CategoryCommandsTests.swift`（追加测试）

**Interfaces:**
- Consumes: Task 2 的 `CategoryCommands` 与错误枚举、`DefaultDataSeeder`（造 isBuiltIn 数据）、`TransactionCommands`（造流水引用）。
- Produces:
  - `func setArchived(uuid: UUID, isArchived: Bool) throws` — 只标自身；「归档父类连带子类不可选」是读路径口径（Task 5 落地）。
  - `func softDeleteCategory(uuid: UUID) throws` — 活跃流水引用或活跃子分类存在则阻断（设计文档 §4 软删阻断表）。
  - `func restoreDefaultCategories() throws` — 对全部 `isBuiltIn` 分类复位 `isArchived` / `isSoftDeleted`（识别机制即 isBuiltIn，无硬删故不会缺行）。

- [ ] **Step 1: 追加失败测试**

```swift
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
        // 内置子分类直接标软删（绕过流水阻断场景，模拟历史删除）
        let builtInChild = try context.fetch(
            FetchDescriptor<StoredCategory>(predicate: #Predicate { $0.isBuiltIn && $0.parentID != nil })
        ).first!
        try commands.softDeleteCategory(uuid: builtInChild.uuid)

        try commands.restoreDefaultCategories()

        #expect(!builtIn.isArchived)
        #expect(!builtInChild.isSoftDeleted)
        #expect(custom.isArchived) // 自定义分类不受影响
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `TEST CategoryCommandsTests`
Expected: 编译失败 "value of type 'CategoryCommands' has no member 'setArchived'"

- [ ] **Step 3: 追加实现（`CategoryCommands` 内）**

```swift
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
            FetchDescriptor<StoredTransaction>(predicate: #Predicate {
                !$0.isSoftDeleted && $0.category?.uuid == uuid
            })
        )
        guard referenceCount == 0 else { throw CategoryCommandError.hasActiveTransactions }
        guard try activeChildCount(of: uuid) == 0 else { throw CategoryCommandError.hasActiveChildren }
        category.isSoftDeleted = true
        category.updatedAt = .now
        try context.save()
    }

    /// 恢复默认分类：对全部内置分类复位归档/软删标记（isBuiltIn 即识别机制，
    /// 全库无硬删除故内置行永不缺失；用户改名/改图标不回滚）。
    func restoreDefaultCategories() throws {
        let builtIns = try context.fetch(
            FetchDescriptor<StoredCategory>(predicate: #Predicate { $0.isBuiltIn })
        )
        for category in builtIns where category.isArchived || category.isSoftDeleted {
            category.isArchived = false
            category.isSoftDeleted = false
            category.updatedAt = .now
        }
        try context.save()
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `TEST CategoryCommandsTests`
Expected: PASS（15 tests）

- [ ] **Step 5: 提交**

```bash
git add zanzan/Core/Commands/CategoryCommands.swift zanzanTests/CategoryCommandsTests.swift
git commit -m "✨ feat(categories): 归档/软删阻断/恢复默认分类命令"
```

---

### Task 4: CategoryCommands — 同层排序

**Files:**
- Modify: `zanzan/Core/Commands/CategoryCommands.swift`（追加一个方法）
- Test: `zanzanTests/CategoryCommandsTests.swift`（追加测试）

**Interfaces:**
- Consumes: Task 2/3 的 `CategoryCommands`。
- Produces: `func reorderCategories(orderedUUIDs: [UUID]) throws` — 按传入顺序重写 `sortOrder = index`；全部条目必须活跃且属同一 `(parentID, kind)` 层，否则 `reorderScopeMismatch`。

- [ ] **Step 1: 追加失败测试**

```swift
    // MARK: - 排序

    @Test func 同层重排按传入顺序写入() throws {
        let context = try makeContext()
        let a = try makeCategory(context, name: "餐饮")
        let b = try makeCategory(context, name: "交通")
        let c = try makeCategory(context, name: "购物")
        try CategoryCommands(context: context).reorderCategories(orderedUUIDs: [c.uuid, a.uuid, b.uuid])
        #expect(c.sortOrder == 0)
        #expect(a.sortOrder == 1)
        #expect(b.sortOrder == 2)
    }

    @Test func 跨层混排被拒() throws {
        let context = try makeContext()
        let parent = try makeCategory(context, name: "餐饮")
        let child = try makeCategory(context, name: "早餐", parentID: parent.uuid)
        #expect(throws: CategoryCommandError.self) {
            try CategoryCommands(context: context).reorderCategories(orderedUUIDs: [parent.uuid, child.uuid])
        }
    }

    @Test func 跨方向混排被拒() throws {
        let context = try makeContext()
        let expense = try makeCategory(context, name: "餐饮")
        let income = try makeCategory(context, name: "工资", kind: .income)
        #expect(throws: CategoryCommandError.self) {
            try CategoryCommands(context: context).reorderCategories(orderedUUIDs: [income.uuid, expense.uuid])
        }
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `TEST CategoryCommandsTests`
Expected: 编译失败 "no member 'reorderCategories'"

- [ ] **Step 3: 追加实现（`CategoryCommands` 内）**

```swift
    /// 同层重排：按传入顺序重写 sortOrder。要求全部条目活跃且同 (parentID, kind) 层。
    func reorderCategories(orderedUUIDs: [UUID]) throws {
        let categories = try orderedUUIDs.map(fetchActiveCategory)
        guard let first = categories.first else { return }
        let isSameScope = categories.allSatisfy {
            $0.parentID == first.parentID && $0.kindRawValue == first.kindRawValue
        }
        guard isSameScope else { throw CategoryCommandError.reorderScopeMismatch }
        for (index, category) in categories.enumerated() where category.sortOrder != index {
            category.sortOrder = index
            category.updatedAt = .now
        }
        try context.save()
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `TEST CategoryCommandsTests`
Expected: PASS（18 tests）

- [ ] **Step 5: 提交**

```bash
git add zanzan/Core/Commands/CategoryCommands.swift zanzanTests/CategoryCommandsTests.swift
git commit -m "✨ feat(categories): 同层分类排序命令"
```

---

### Task 5: CategoryTreeProjector — 分类树投影（管理列表 + 记账可选树）

**Files:**
- Create: `zanzan/Core/Projections/CategoryTreeProjector.swift`
- Test: `zanzanTests/CategoryTreeProjectorTests.swift`

**Interfaces:**
- Consumes: `StoredCategory`。
- Produces:
  ```swift
  struct CategoryTreeNode {
      let category: StoredCategory
      let children: [StoredCategory]
  }
  struct CategoryTreeProjector {
      let context: ModelContext
      /// includeArchived=true → 分类管理页（归档照常列出，UI 自行折叠）；
      /// false → 记账 picker（归档父连带全部子剔除、归档子剔除）
      func tree(kind: TransactionKind, includeArchived: Bool) throws -> [CategoryTreeNode]
  }
  ```
- 排序：一级按 `sortOrder`，children 同。软删永远剔除（谓词下推）。

- [ ] **Step 1: 写失败测试**

```swift
import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct CategoryTreeProjectorTests {
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

    @Test func 两级树按排序返回() throws {
        let context = try makeContext()
        let dining = try makeCategory(context, name: "餐饮")
        let transport = try makeCategory(context, name: "交通")
        _ = try makeCategory(context, name: "午餐", parentID: dining.uuid)
        _ = try makeCategory(context, name: "早餐", parentID: dining.uuid)
        _ = try makeCategory(context, name: "工资", kind: .income)

        let tree = try CategoryTreeProjector(context: context).tree(kind: .expense, includeArchived: true)
        #expect(tree.map(\.category.name) == ["餐饮", "交通"])
        #expect(tree[0].children.map(\.name) == ["午餐", "早餐"])
        #expect(tree[1].children.isEmpty)
        _ = transport
    }

    @Test func 记账树剔除归档子分类() throws {
        let context = try makeContext()
        let dining = try makeCategory(context, name: "餐饮")
        let breakfast = try makeCategory(context, name: "早餐", parentID: dining.uuid)
        try CategoryCommands(context: context).setArchived(uuid: breakfast.uuid, isArchived: true)

        let selectable = try CategoryTreeProjector(context: context).tree(kind: .expense, includeArchived: false)
        #expect(selectable[0].children.isEmpty)
        let manage = try CategoryTreeProjector(context: context).tree(kind: .expense, includeArchived: true)
        #expect(manage[0].children.map(\.name) == ["早餐"])
    }

    @Test func 归档父分类连带子分类剔除() throws {
        let context = try makeContext()
        let dining = try makeCategory(context, name: "餐饮")
        _ = try makeCategory(context, name: "早餐", parentID: dining.uuid)
        _ = try makeCategory(context, name: "交通")
        try CategoryCommands(context: context).setArchived(uuid: dining.uuid, isArchived: true)

        let selectable = try CategoryTreeProjector(context: context).tree(kind: .expense, includeArchived: false)
        #expect(selectable.map(\.category.name) == ["交通"])
    }

    @Test func 软删分类不出现在任何树() throws {
        let context = try makeContext()
        let dining = try makeCategory(context, name: "餐饮")
        try CategoryCommands(context: context).softDeleteCategory(uuid: dining.uuid)
        let manage = try CategoryTreeProjector(context: context).tree(kind: .expense, includeArchived: true)
        #expect(manage.isEmpty)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `TEST CategoryTreeProjectorTests`
Expected: 编译失败 "cannot find 'CategoryTreeProjector' in scope"

- [ ] **Step 3: 最小实现**

```swift
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
```

- [ ] **Step 4: 跑测试确认通过**

Run: `TEST CategoryTreeProjectorTests`
Expected: PASS（4 tests）

- [ ] **Step 5: 提交**

```bash
git add zanzan/Core/Projections/CategoryTreeProjector.swift zanzanTests/CategoryTreeProjectorTests.swift
git commit -m "✨ feat(categories): 分类树投影（归档连带不可选口径）"
```

---

### Task 6: StoredTransaction 统计口径扩展

**Files:**
- Create: `zanzan/Core/Projections/StoredTransaction+StatsAmounts.swift`
- Test: `zanzanTests/TransactionStatsAmountsTests.swift`

**Interfaces:**
- Consumes: `StoredTransaction`（`kind` / `settlementKind` / `isExcludedFromStats` / `amountMinorUnits` / `feeMinorUnits`）。
- Produces（Task 7/8 共用的统计口径，DRY 收敛点）：
  ```swift
  extension StoredTransaction {
      /// 统计收入（分）：income 且非报销到账计 amount；isExcludedFromStats / 未知 kind → 0
      var statsIncomeMinorUnits: Int
      /// 统计支出（分）：expense 计 amount；fee 恒为流出计入支出（转账手续费/分期利息，
      /// 设计文档 5.4 + 裁决 11）；isExcludedFromStats → 0
      var statsExpenseMinorUnits: Int
  }
  ```

**口径依据（数据库设计文档 5.4）：** `isExcludedFromStats` 该笔不计收支统计；`feeMinorUnits` 计入支出统计；`settlementKind == reimbursement` 的入账是费用冲减不计收入。退款冲减对应分类支出需 join 关联表，M2 报销切片一并实现（本切片无退款数据源）。

- [ ] **Step 1: 写失败测试**

```swift
import Foundation
import Testing
@testable import zanzan

struct TransactionStatsAmountsTests {
    private func makeTransaction(kind: TransactionKind, amount: Int, fee: Int = 0) -> StoredTransaction {
        let tx = StoredTransaction(kind: kind, amountMinorUnits: amount, occurredAt: .now, ledgerID: UUID())
        tx.feeMinorUnits = fee
        return tx
    }

    @Test func 支出计支出不计收入() {
        let tx = makeTransaction(kind: .expense, amount: 1_000)
        #expect(tx.statsExpenseMinorUnits == 1_000)
        #expect(tx.statsIncomeMinorUnits == 0)
    }

    @Test func 收入计收入不计支出() {
        let tx = makeTransaction(kind: .income, amount: 2_000)
        #expect(tx.statsIncomeMinorUnits == 2_000)
        #expect(tx.statsExpenseMinorUnits == 0)
    }

    @Test func 转账手续费计入支出() {
        let tx = makeTransaction(kind: .transfer, amount: 10_000, fee: 50)
        #expect(tx.statsExpenseMinorUnits == 50)
        #expect(tx.statsIncomeMinorUnits == 0)
    }

    @Test func 报销到账不计收入() {
        let tx = makeTransaction(kind: .income, amount: 3_000)
        tx.settlementKindRawValue = TransactionLinkKind.reimbursement.rawValue
        #expect(tx.statsIncomeMinorUnits == 0)
    }

    @Test func 不计统计流水两侧归零() {
        let tx = makeTransaction(kind: .expense, amount: 1_000)
        tx.isExcludedFromStats = true
        #expect(tx.statsExpenseMinorUnits == 0)
        #expect(tx.statsIncomeMinorUnits == 0)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `TEST TransactionStatsAmountsTests`
Expected: 编译失败 "has no member 'statsExpenseMinorUnits'"

- [ ] **Step 3: 最小实现**

```swift
import Foundation

/// 统计口径派生（设计文档 5.4）：投影层共用，勿在页面重算。
/// 退款冲减对应分类支出需 join StoredTransactionLink，M2 报销切片实现。
extension StoredTransaction {
    /// 统计收入（分）：income 且非报销到账计 amount（报销到账是费用冲减，计入会虚增收入）。
    var statsIncomeMinorUnits: Int {
        guard !isExcludedFromStats, kind == .income, settlementKind != .reimbursement else { return 0 }
        return amountMinorUnits
    }

    /// 统计支出（分）：expense 计 amount；fee 恒为流出一并计入（转账手续费/分期利息）。
    var statsExpenseMinorUnits: Int {
        guard !isExcludedFromStats else { return 0 }
        return (kind == .expense ? amountMinorUnits : 0) + feeMinorUnits
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `TEST TransactionStatsAmountsTests`
Expected: PASS（5 tests）

- [ ] **Step 5: 提交**

```bash
git add zanzan/Core/Projections/StoredTransaction+StatsAmounts.swift zanzanTests/TransactionStatsAmountsTests.swift
git commit -m "✨ feat(stats): 流水统计口径派生（报销剔除/fee 计支出）"
```

---

### Task 7: MonthlyStatsProjector — 月收支汇总 + 分类排行（二级 rollup）

**Files:**
- Create: `zanzan/Core/Projections/MonthlyStatsProjector.swift`
- Test: `zanzanTests/MonthlyStatsProjectorTests.swift`

**Interfaces:**
- Consumes: Task 6 的 `statsIncomeMinorUnits` / `statsExpenseMinorUnits`、`StoredTransaction`、`StoredCategory`。
- Produces:
  ```swift
  struct MonthlyStats {
      struct ChildStat { let category: StoredCategory; let amountMinorUnits: Int }
      struct CategoryStat {
          let category: StoredCategory          // 一级分类
          let directMinorUnits: Int             // 父类直挂金额
          let children: [ChildStat]             // 子类汇总（金额降序）
          var totalMinorUnits: Int { directMinorUnits + children.reduce(0) { $0 + $1.amountMinorUnits } }
      }
      let incomeTotalMinorUnits: Int
      let expenseTotalMinorUnits: Int           // 含 fee
      let feeTotalMinorUnits: Int               // 「利息手续费」口径（裁决 11），无分类归属
      let expenseRanking: [CategoryStat]        // total 降序
      let incomeRanking: [CategoryStat]
  }
  struct MonthlyStatsProjector {
      let context: ModelContext
      func stats(ledgerID: UUID, year: Int, month: Int, calendar: Calendar = .current) throws -> MonthlyStats
  }
  ```
- 谓词下推：`!isSoftDeleted && ledgerID == && occurredAt ∈ [月初, 下月初) && !isExcludedFromStats`（命中复合索引前两列 + 窗口）。
- rollup：流水挂二级分类 → 金额入其父的 `children`；挂一级 → `directMinorUnits`。归档分类历史统计照常。占比是 UI 层除法，不在投影算。
- 防御：`category == nil` 或父不可解析的收支流水计入 total，不进 ranking（脏数据不炸投影）。

- [ ] **Step 1: 写失败测试**

```swift
import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct MonthlyStatsProjectorTests {
    private struct Env {
        let context: ModelContext
        let ledgerID: UUID
        let accountUUID: UUID
    }

    private func makeEnv() throws -> Env {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let ledger = try LedgerCommands(context: context).createLedger(LedgerDraft(name: "测试账本"))
        var accountDraft = AccountDraft()
        accountDraft.name = "现金"
        let account = try AccountCommands(context: context).createAccount(accountDraft)
        return Env(context: context, ledgerID: ledger.uuid, accountUUID: account.uuid)
    }

    private func makeCategory(
        _ env: Env, name: String, kind: TransactionKind = .expense, parentID: UUID? = nil
    ) throws -> StoredCategory {
        var draft = CategoryDraft()
        draft.name = name
        draft.kind = kind
        draft.parentID = parentID
        return try CategoryCommands(context: env.context).createCategory(draft)
    }

    private func record(
        _ env: Env, kind: TransactionKind, amount: String, categoryUUID: UUID?, day: Int, month: Int = 7
    ) throws -> StoredTransaction {
        var draft = TransactionDraft()
        draft.kind = kind
        draft.amountString = amount
        draft.accountUUID = env.accountUUID
        draft.categoryUUID = categoryUUID
        draft.occurredAt = Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day))!
        return try TransactionCommands(context: env.context).recordTransaction(draft, ledgerID: env.ledgerID)
    }

    @Test func 月收支汇总只算当月当账本() throws {
        let env = try makeEnv()
        let food = try makeCategory(env, name: "餐饮")
        let salary = try makeCategory(env, name: "工资", kind: .income)
        _ = try record(env, kind: .expense, amount: "100", categoryUUID: food.uuid, day: 5)
        _ = try record(env, kind: .income, amount: "5000", categoryUUID: salary.uuid, day: 10)
        _ = try record(env, kind: .expense, amount: "999", categoryUUID: food.uuid, day: 5, month: 6) // 上月

        let stats = try MonthlyStatsProjector(context: env.context)
            .stats(ledgerID: env.ledgerID, year: 2026, month: 7)
        #expect(stats.expenseTotalMinorUnits == 10_000)
        #expect(stats.incomeTotalMinorUnits == 500_000)
    }

    @Test func 二级金额汇入父类且并列展示() throws {
        let env = try makeEnv()
        let dining = try makeCategory(env, name: "餐饮")
        let breakfast = try makeCategory(env, name: "早餐", parentID: dining.uuid)
        let lunch = try makeCategory(env, name: "午餐", parentID: dining.uuid)
        _ = try record(env, kind: .expense, amount: "10", categoryUUID: dining.uuid, day: 1)   // 父直挂
        _ = try record(env, kind: .expense, amount: "20", categoryUUID: breakfast.uuid, day: 2)
        _ = try record(env, kind: .expense, amount: "30", categoryUUID: lunch.uuid, day: 3)

        let stats = try MonthlyStatsProjector(context: env.context)
            .stats(ledgerID: env.ledgerID, year: 2026, month: 7)
        let diningStat = stats.expenseRanking.first { $0.category.uuid == dining.uuid }!
        #expect(diningStat.directMinorUnits == 1_000)
        #expect(diningStat.totalMinorUnits == 6_000)
        #expect(diningStat.children.map(\.amountMinorUnits) == [3_000, 2_000]) // 子类降序
    }

    @Test func 排行按总额降序() throws {
        let env = try makeEnv()
        let dining = try makeCategory(env, name: "餐饮")
        let transport = try makeCategory(env, name: "交通")
        _ = try record(env, kind: .expense, amount: "10", categoryUUID: dining.uuid, day: 1)
        _ = try record(env, kind: .expense, amount: "50", categoryUUID: transport.uuid, day: 2)

        let stats = try MonthlyStatsProjector(context: env.context)
            .stats(ledgerID: env.ledgerID, year: 2026, month: 7)
        #expect(stats.expenseRanking.map(\.category.name) == ["交通", "餐饮"])
    }

    @Test func 转账手续费计入支出与fee口径() throws {
        let env = try makeEnv()
        var targetDraft = AccountDraft()
        targetDraft.name = "储蓄卡"
        let target = try AccountCommands(context: env.context).createAccount(targetDraft)
        var draft = TransactionDraft()
        draft.kind = .transfer
        draft.amountString = "1000"
        draft.feeString = "5"
        draft.accountUUID = env.accountUUID
        draft.targetAccountUUID = target.uuid
        draft.occurredAt = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 8))!
        _ = try TransactionCommands(context: env.context).recordTransaction(draft, ledgerID: env.ledgerID)

        let stats = try MonthlyStatsProjector(context: env.context)
            .stats(ledgerID: env.ledgerID, year: 2026, month: 7)
        #expect(stats.expenseTotalMinorUnits == 500)
        #expect(stats.feeTotalMinorUnits == 500)
        #expect(stats.expenseRanking.isEmpty) // fee 无分类归属，不进排行
    }

    @Test func 不计统计流水被剔除() throws {
        let env = try makeEnv()
        let food = try makeCategory(env, name: "餐饮")
        let tx = try record(env, kind: .expense, amount: "100", categoryUUID: food.uuid, day: 5)
        tx.isExcludedFromStats = true
        try env.context.save()

        let stats = try MonthlyStatsProjector(context: env.context)
            .stats(ledgerID: env.ledgerID, year: 2026, month: 7)
        #expect(stats.expenseTotalMinorUnits == 0)
        #expect(stats.expenseRanking.isEmpty)
    }

    @Test func 收入排行独立于支出() throws {
        let env = try makeEnv()
        let salary = try makeCategory(env, name: "工资", kind: .income)
        let food = try makeCategory(env, name: "餐饮")
        _ = try record(env, kind: .income, amount: "5000", categoryUUID: salary.uuid, day: 1)
        _ = try record(env, kind: .expense, amount: "100", categoryUUID: food.uuid, day: 2)

        let stats = try MonthlyStatsProjector(context: env.context)
            .stats(ledgerID: env.ledgerID, year: 2026, month: 7)
        #expect(stats.incomeRanking.map(\.category.name) == ["工资"])
        #expect(stats.expenseRanking.map(\.category.name) == ["餐饮"])
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `TEST MonthlyStatsProjectorTests`
Expected: 编译失败 "cannot find 'MonthlyStatsProjector' in scope"

- [ ] **Step 3: 最小实现**

```swift
import Foundation
import SwiftData

/// 月度统计只读投影（设计文档 5.3 rollup 口径 / 5.4 统计口径）。
/// 谓词收窄到账本 × 月窗口后一次取回，内存做分类 rollup（关系穿越谓词表达不了）。
struct MonthlyStats {
    struct ChildStat {
        let category: StoredCategory
        let amountMinorUnits: Int
    }

    struct CategoryStat {
        /// 一级分类；「父类直挂」与「子类汇总」并列展示（设计文档 5.3）
        let category: StoredCategory
        let directMinorUnits: Int
        let children: [ChildStat]
        var totalMinorUnits: Int { directMinorUnits + children.reduce(0) { $0 + $1.amountMinorUnits } }
    }

    let incomeTotalMinorUnits: Int
    /// 含 fee（fee 恒为流出计入支出统计）
    let expenseTotalMinorUnits: Int
    /// 「利息手续费」合计（裁决 11：fee 无分类归属，由投影器单列口径）
    let feeTotalMinorUnits: Int
    let expenseRanking: [CategoryStat]
    let incomeRanking: [CategoryStat]
}

struct MonthlyStatsProjector {
    let context: ModelContext

    func stats(ledgerID: UUID, year: Int, month: Int, calendar: Calendar = .current) throws -> MonthlyStats {
        guard
            let monthStart = calendar.date(from: DateComponents(year: year, month: month)),
            let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: monthStart)
        else { throw MonthlyStatsError.invalidMonth }

        let id: UUID? = ledgerID
        let transactions = try context.fetch(
            FetchDescriptor<StoredTransaction>(predicate: #Predicate {
                !$0.isSoftDeleted && $0.ledgerID == id
                    && $0.occurredAt >= monthStart && $0.occurredAt < nextMonthStart
                    && !$0.isExcludedFromStats
            })
        )

        return MonthlyStats(
            incomeTotalMinorUnits: transactions.reduce(0) { $0 + $1.statsIncomeMinorUnits },
            expenseTotalMinorUnits: transactions.reduce(0) { $0 + $1.statsExpenseMinorUnits },
            feeTotalMinorUnits: transactions.reduce(0) { $0 + $1.feeMinorUnits },
            expenseRanking: ranking(of: transactions, kind: .expense) { $0.amountMinorUnits },
            incomeRanking: ranking(of: transactions, kind: .income) { $0.statsIncomeMinorUnits }
        )
    }

    /// 分类 rollup：二级金额汇入父类。amount 闭包区分口径——
    /// 支出排行计 amount（fee 无分类不进排行），收入排行计报销剔除后口径。
    private func ranking(
        of transactions: [StoredTransaction],
        kind: TransactionKind,
        amount: (StoredTransaction) -> Int
    ) -> [MonthlyStats.CategoryStat] {
        var directByParent: [UUID: Int] = [:]
        var childAmounts: [UUID: Int] = [:]
        var categoriesByUUID: [UUID: StoredCategory] = [:]
        var parentOfChild: [UUID: StoredCategory] = [:]

        for tx in transactions where tx.kind == kind {
            guard let category = tx.category else { continue } // 脏数据防御：计 total 不进排行
            let value = amount(tx)
            guard value > 0 else { continue }
            categoriesByUUID[category.uuid] = category
            if let parentID = category.parentID, let parent = fetchCategory(parentID) {
                childAmounts[category.uuid, default: 0] += value
                parentOfChild[category.uuid] = parent
                categoriesByUUID[parent.uuid] = parent
            } else {
                directByParent[category.uuid, default: 0] += value
            }
        }

        var childrenByParent: [UUID: [MonthlyStats.ChildStat]] = [:]
        for (childUUID, value) in childAmounts {
            guard let parent = parentOfChild[childUUID], let child = categoriesByUUID[childUUID] else { continue }
            childrenByParent[parent.uuid, default: []]
                .append(MonthlyStats.ChildStat(category: child, amountMinorUnits: value))
        }

        let parentUUIDs = Set(directByParent.keys).union(childrenByParent.keys)
        return parentUUIDs
            .compactMap { uuid -> MonthlyStats.CategoryStat? in
                guard let category = categoriesByUUID[uuid] else { return nil }
                let children = (childrenByParent[uuid] ?? []).sorted { $0.amountMinorUnits > $1.amountMinorUnits }
                return MonthlyStats.CategoryStat(
                    category: category,
                    directMinorUnits: directByParent[uuid] ?? 0,
                    children: children
                )
            }
            .sorted { $0.totalMinorUnits > $1.totalMinorUnits }
    }

    private func fetchCategory(_ uuid: UUID) -> StoredCategory? {
        try? context.fetch(
            FetchDescriptor<StoredCategory>(predicate: #Predicate { $0.uuid == uuid })
        ).first
    }
}

enum MonthlyStatsError: LocalizedError {
    case invalidMonth

    var errorDescription: String? {
        switch self {
        case .invalidMonth: "无效的统计月份"
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `TEST MonthlyStatsProjectorTests`
Expected: PASS（6 tests）

- [ ] **Step 5: 提交**

```bash
git add zanzan/Core/Projections/MonthlyStatsProjector.swift zanzanTests/MonthlyStatsProjectorTests.swift
git commit -m "✨ feat(stats): 月收支汇总与分类排行投影（二级 rollup）"
```

---

### Task 8: TransactionListProjection — 明细筛选谓词 + 日/月小计分组

**Files:**
- Create: `zanzan/Core/Projections/TransactionListProjection.swift`
- Test: `zanzanTests/TransactionListProjectionTests.swift`

**Interfaces:**
- Consumes: Task 6 的 `statsIncomeMinorUnits` / `statsExpenseMinorUnits`、`StoredTransaction`。
- Produces:
  ```swift
  struct TransactionListFilter {
      var ledgerID: UUID
      var kind: TransactionKind? = nil       // nil = 全部类型
      var accountUUID: UUID? = nil           // nil = 全部账户；命中收支账户或转账双方
      func fetchDescriptor() -> FetchDescriptor<StoredTransaction>  // occurredAt 降序
  }
  enum TransactionListGrouping {
      struct DayGroup { let day: Date; let incomeTotalMinorUnits: Int; let expenseTotalMinorUnits: Int; let items: [StoredTransaction] }
      struct MonthGroup { let month: Date; let incomeTotalMinorUnits: Int; let expenseTotalMinorUnits: Int; let days: [DayGroup] }
      static func monthGroups(of transactions: [StoredTransaction], calendar: Calendar = .current) -> [MonthGroup]
  }
  ```
- 小计口径复用 Task 6 扩展（`isExcludedFromStats` 的流水**照常显示在 items**，仅不计小计——扩展已归零，直接求和即可）。
- 分组假定输入已按 `occurredAt` 降序（fetchDescriptor 保证），组序月降序、日降序。

- [ ] **Step 1: 写失败测试**

```swift
import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct TransactionListProjectionTests {
    private struct Env {
        let context: ModelContext
        let ledgerID: UUID
        let accountUUID: UUID
        let categoryUUID: UUID
    }

    private func makeEnv() throws -> Env {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let ledger = try LedgerCommands(context: context).createLedger(LedgerDraft(name: "测试账本"))
        var accountDraft = AccountDraft()
        accountDraft.name = "现金"
        let account = try AccountCommands(context: context).createAccount(accountDraft)
        var categoryDraft = CategoryDraft()
        categoryDraft.name = "餐饮"
        let category = try CategoryCommands(context: context).createCategory(categoryDraft)
        return Env(context: context, ledgerID: ledger.uuid, accountUUID: account.uuid, categoryUUID: category.uuid)
    }

    private func record(
        _ env: Env, kind: TransactionKind = .expense, amount: String = "10",
        accountUUID: UUID? = nil, day: Int, month: Int = 7
    ) throws -> StoredTransaction {
        var draft = TransactionDraft()
        draft.kind = kind
        draft.amountString = amount
        draft.accountUUID = accountUUID ?? env.accountUUID
        draft.categoryUUID = kind == .transfer ? nil : env.categoryUUID
        draft.occurredAt = Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
        return try TransactionCommands(context: env.context).recordTransaction(draft, ledgerID: env.ledgerID)
    }

    @Test func 按类型筛选() throws {
        let env = try makeEnv()
        var incomeCategoryDraft = CategoryDraft()
        incomeCategoryDraft.name = "工资"
        incomeCategoryDraft.kind = .income
        let incomeCategory = try CategoryCommands(context: env.context).createCategory(incomeCategoryDraft)
        _ = try record(env, day: 1)
        var incomeDraft = TransactionDraft()
        incomeDraft.kind = .income
        incomeDraft.amountString = "5000"
        incomeDraft.accountUUID = env.accountUUID
        incomeDraft.categoryUUID = incomeCategory.uuid
        _ = try TransactionCommands(context: env.context).recordTransaction(incomeDraft, ledgerID: env.ledgerID)

        var filter = TransactionListFilter(ledgerID: env.ledgerID)
        filter.kind = .expense
        let results = try env.context.fetch(filter.fetchDescriptor())
        #expect(results.count == 1)
        #expect(results[0].kind == .expense)
    }

    @Test func 按账户筛选命中转账双方() throws {
        let env = try makeEnv()
        var otherDraft = AccountDraft()
        otherDraft.name = "储蓄卡"
        let other = try AccountCommands(context: env.context).createAccount(otherDraft)
        _ = try record(env, day: 1) // 现金支出
        var transfer = TransactionDraft()
        transfer.kind = .transfer
        transfer.amountString = "100"
        transfer.accountUUID = env.accountUUID
        transfer.targetAccountUUID = other.uuid
        _ = try TransactionCommands(context: env.context).recordTransaction(transfer, ledgerID: env.ledgerID)

        var filter = TransactionListFilter(ledgerID: env.ledgerID)
        filter.accountUUID = other.uuid
        let results = try env.context.fetch(filter.fetchDescriptor())
        #expect(results.count == 1)
        #expect(results[0].kind == .transfer)
    }

    @Test func 无筛选返回账本全量降序() throws {
        let env = try makeEnv()
        _ = try record(env, day: 1)
        _ = try record(env, day: 15)
        let filter = TransactionListFilter(ledgerID: env.ledgerID)
        let results = try env.context.fetch(filter.fetchDescriptor())
        #expect(results.count == 2)
        #expect(results[0].occurredAt > results[1].occurredAt)
    }

    @Test func 日月分组含小计() throws {
        let env = try makeEnv()
        _ = try record(env, amount: "10", day: 1)
        _ = try record(env, amount: "20", day: 1)
        _ = try record(env, amount: "30", day: 15)
        _ = try record(env, amount: "40", day: 1, month: 6)

        let filter = TransactionListFilter(ledgerID: env.ledgerID)
        let results = try env.context.fetch(filter.fetchDescriptor())
        let months = TransactionListGrouping.monthGroups(of: results)

        #expect(months.count == 2)
        #expect(months[0].expenseTotalMinorUnits == 6_000) // 7 月
        #expect(months[0].days.count == 2)
        #expect(months[0].days[0].expenseTotalMinorUnits == 3_000) // 15 日在前（降序）
        #expect(months[0].days[1].expenseTotalMinorUnits == 3_000) // 1 日两笔
        #expect(months[1].expenseTotalMinorUnits == 4_000) // 6 月
    }

    @Test func 不计统计流水显示但不进小计() throws {
        let env = try makeEnv()
        _ = try record(env, amount: "10", day: 1)
        let excluded = try record(env, amount: "99", day: 1)
        excluded.isExcludedFromStats = true
        try env.context.save()

        let filter = TransactionListFilter(ledgerID: env.ledgerID)
        let results = try env.context.fetch(filter.fetchDescriptor())
        let months = TransactionListGrouping.monthGroups(of: results)
        #expect(months[0].days[0].items.count == 2)
        #expect(months[0].days[0].expenseTotalMinorUnits == 1_000)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `TEST TransactionListProjectionTests`
Expected: 编译失败 "cannot find 'TransactionListFilter' in scope"

- [ ] **Step 3: 最小实现**

```swift
import Foundation
import SwiftData

/// 明细列表筛选 + 日/月小计投影（路线图 M1「明细页打磨」逻辑层）。
/// 谓词下推命中复合索引 (isSoftDeleted, ledgerID, occurredAt)；
/// 账户筛选穿关系（收支账户或转账双方），小计口径复用 statsIncome/Expense 派生。
struct TransactionListFilter {
    var ledgerID: UUID
    /// nil = 全部类型
    var kind: TransactionKind? = nil
    /// nil = 全部账户；命中收支账户或转账双方
    var accountUUID: UUID? = nil

    func fetchDescriptor() -> FetchDescriptor<StoredTransaction> {
        let id: UUID? = ledgerID
        let kindRaw = kind?.rawValue
        let accountID = accountUUID
        return FetchDescriptor<StoredTransaction>(
            predicate: #Predicate {
                !$0.isSoftDeleted && $0.ledgerID == id
                    && (kindRaw == nil || $0.kindRawValue == kindRaw)
                    && (accountID == nil || $0.account?.uuid == accountID || $0.targetAccount?.uuid == accountID)
            },
            sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
        )
    }
}

enum TransactionListGrouping {
    struct DayGroup {
        let day: Date
        let incomeTotalMinorUnits: Int
        let expenseTotalMinorUnits: Int
        let items: [StoredTransaction]
    }

    struct MonthGroup {
        let month: Date
        let incomeTotalMinorUnits: Int
        let expenseTotalMinorUnits: Int
        let days: [DayGroup]
    }

    /// 输入须已按 occurredAt 降序（fetchDescriptor 保证）；组序月降、日降。
    /// isExcludedFromStats 的流水照常在 items，仅不计小计（stats 派生已归零）。
    static func monthGroups(of transactions: [StoredTransaction], calendar: Calendar = .current) -> [MonthGroup] {
        let byMonth = Dictionary(grouping: transactions) {
            calendar.date(from: calendar.dateComponents([.year, .month], from: $0.occurredAt)) ?? $0.occurredAt
        }
        return byMonth
            .sorted { $0.key > $1.key }
            .map { month, monthItems in
                let days = Dictionary(grouping: monthItems) { calendar.startOfDay(for: $0.occurredAt) }
                    .sorted { $0.key > $1.key }
                    .map { day, dayItems in
                        DayGroup(
                            day: day,
                            incomeTotalMinorUnits: dayItems.reduce(0) { $0 + $1.statsIncomeMinorUnits },
                            expenseTotalMinorUnits: dayItems.reduce(0) { $0 + $1.statsExpenseMinorUnits },
                            items: dayItems
                        )
                    }
                return MonthGroup(
                    month: month,
                    incomeTotalMinorUnits: days.reduce(0) { $0 + $1.incomeTotalMinorUnits },
                    expenseTotalMinorUnits: days.reduce(0) { $0 + $1.expenseTotalMinorUnits },
                    days: days
                )
            }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `TEST TransactionListProjectionTests`
Expected: PASS（5 tests）

- [ ] **Step 5: 提交**

```bash
git add zanzan/Core/Projections/TransactionListProjection.swift zanzanTests/TransactionListProjectionTests.swift
git commit -m "✨ feat(transactions): 明细筛选谓词与日月小计投影"
```

---

### Task 9: 全量回归 + 路线图备注

**Files:**
- Modify: `docs/功能路线图.md`（M1 三条目各加「逻辑层已备」备注，不挪 §1——UI 未做，切片未完整交付）

- [ ] **Step 1: 跑全量单元测试**

Run:
```bash
xcodebuild test -project zanzan.xcodeproj -scheme zanzan -only-testing:zanzanTests \
  -destination 'platform=iOS Simulator,name=iPhone 17' -quiet
```
Expected: 全绿（原 64 + 新增 ≈46）

- [ ] **Step 2: 更新路线图**

在 `docs/功能路线图.md` §2 M1 三条目末尾各追加 `（逻辑层已合入：Draft/Commands/Projector 就绪，待 UI）` 字样。

- [ ] **Step 3: 提交**

```bash
git add docs/功能路线图.md
git commit -m "📝 docs(product): 标注 M1 逻辑层就绪待 UI"
```

---

## Self-Review

- **Spec 覆盖**：分类增删改✅（Task 1-2）/归档✅/恢复默认✅（Task 3）/排序✅（Task 4）；账本专属分类明确暂缓（ledgerID 恒 nil）。统计：月收支汇总✅、分类排行 + 二级 rollup✅、fee 口径✅（Task 6-7）；占比为 UI 除法不在逻辑层。明细：筛选（类型/账户）✅、日/月小计✅（Task 8）；账本切换器纯 UI，无逻辑层工作。退款冲减支出显式推迟到 M2（本切片无退款写路径）。
- **占位符扫描**：无 TBD/TODO；每步含完整代码与命令。
- **类型一致性**：`CategoryCommandError` 全部 case 在 Task 2 一次定义；`statsIncomeMinorUnits`/`statsExpenseMinorUnits` 命名在 Task 6/7/8 一致；`CategoryDraft.Validated` 字段与 Commands 消费处一致。
