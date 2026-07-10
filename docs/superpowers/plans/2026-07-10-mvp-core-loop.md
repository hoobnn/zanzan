# MVP 核心闭环（账本/账户/分类种子/记一笔）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 打通「首启种子 → 账本/账户管理 → 记一笔流水 → 明细列表」的可用闭环，全程 iOS 26+ 原生 UI，TDD 全绿。

**Architecture:** 按架构 spec（`docs/superpowers/specs/2026-07-06-architecture-design.md`）分层：写路径 `*Draft`（校验归一化）→ `*Commands`（不变量 + 显式 `save()`）；读路径简单列表 `@Query` 谓词下推、余额走 `AccountBalanceProjector` 派生；UI 全部原生 SwiftUI（List/Form/TabView/NavigationStack，系统自动 Liquid Glass，不做自定义装饰层）。MVP 刻意不做：多币种（锁 CNY、`fxRateToBase` 恒 nil）、标签/附件/位置/报销、授信池 UI、分类管理 UI（种子分类即全部）、统计页（保留占位）。

**Tech Stack:** Swift 6.2 / SwiftData / SwiftUI / Swift Testing（`@Test` + `#expect`）。

## Global Constraints

- **iOS 26+ 原生 UI**：只用系统组件（List/Form/Picker/DatePicker/ContentUnavailableView/swipeActions/sheet），零自定义 chrome；部署目标 iOS 27 已设。
- 分层铁律：`Features → Core → SwiftData` 单向依赖；**Core 禁 import SwiftUI**；无 ViewModel/DI/Repository。
- 每条业务命令收尾显式 `modelContext.save()`；命令维护 `updatedAt`；全库软删无硬删除。
- 金额换算唯一入口 `MoneyAmount`、展示格式化唯一入口 `formatAmount(_:withSign:)`（设计文档 §4），全库不允许第二种实现。
- 查询下推：本表标量过滤一律 `#Predicate` + `FetchDescriptor`，禁止先取全量再内存 filter。
- `navigationDestination` 目标页禁止在 init 中构造带谓词的 `@Query`；参数化谓词经 initializer 传入的内嵌子视图不受此限（历史教训）。
- 工程为文件系统同步分组：新建 `.swift` 放对目录即入 target，勿改 pbxproj；**禁 `git add -A`**（工作区有未跟踪 `.claude/`）。
- 测试命令：`xcodebuild test -project zanzan.xcodeproj -scheme zanzan -only-testing:zanzanTests -destination 'platform=iOS Simulator,name=iPhone 17' -quiet`，**不要设置 `DEVELOPER_DIR`**。
- 测试统一 `@testable import zanzan` + `@MainActor` struct + `AppModelContainer.make(inMemory: true)`（跑真实现，不 mock 存储）。
- 提交格式（commitlint 强制 gitmoji）：`<emoji> <type>(<scope>): <subject>`，subject 中文、header ≤72 字符，正文加 `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`。
- 错误处理三层防线：Draft 抛 `LocalizedError`（表单内联）；Commands 抛业务错误（View `.alert`）；读路径归一化兜底不 crash。

---

### Task 1: MoneyAmount 换算与 formatAmount 格式化

**Files:**
- Create: `zanzan/Shared/MoneyFormatter.swift`
- Test: `zanzanTests/MoneyFormatterTests.swift`

**Interfaces:**
- Consumes: 无。
- Produces: `MoneyAmount.minorUnits(fromDecimalString:) -> Int?`（非负、≤2 位小数）、`MoneyAmount.signedMinorUnits(fromDecimalString:) -> Int?`（允许负号，账户期初余额用）、`MoneyAmount.decimalString(fromMinorUnits:) -> String`（表单回填）、全局 `formatAmount(_ minorUnits: Int, withSign: Bool = false) -> String`（zh_CN + CNY 锁定，正数 withSign 加 `+`）。

- [x] **Step 1: 写失败测试**

```swift
// zanzanTests/MoneyFormatterTests.swift
import Testing
@testable import zanzan

struct MoneyFormatterTests {
    @Test func 十进制串转分() {
        #expect(MoneyAmount.minorUnits(fromDecimalString: "12.34") == 1234)
        #expect(MoneyAmount.minorUnits(fromDecimalString: "0.5") == 50)
        #expect(MoneyAmount.minorUnits(fromDecimalString: "12") == 1200)
        #expect(MoneyAmount.minorUnits(fromDecimalString: " 8.00 ") == 800)
    }

    @Test func 非法输入返回nil() {
        #expect(MoneyAmount.minorUnits(fromDecimalString: "abc") == nil)
        #expect(MoneyAmount.minorUnits(fromDecimalString: "1.234") == nil) // 超两位小数
        #expect(MoneyAmount.minorUnits(fromDecimalString: "-5") == nil)   // 无符号入口拒负数
        #expect(MoneyAmount.minorUnits(fromDecimalString: "") == nil)
    }

    @Test func 带符号入口允许负数() {
        #expect(MoneyAmount.signedMinorUnits(fromDecimalString: "-5") == -500)
        #expect(MoneyAmount.signedMinorUnits(fromDecimalString: "3.5") == 350)
        #expect(MoneyAmount.signedMinorUnits(fromDecimalString: "-") == nil)
    }

    @Test func 分转十进制串回填() {
        #expect(MoneyAmount.decimalString(fromMinorUnits: 1234) == "12.34")
        #expect(MoneyAmount.decimalString(fromMinorUnits: 1200) == "12")
        #expect(MoneyAmount.decimalString(fromMinorUnits: -350) == "-3.5")
    }

    @Test func 展示格式化锁定zhCN人民币() {
        #expect(formatAmount(1234) == "¥12.34")
        #expect(formatAmount(-1234) == "-¥12.34")
        #expect(formatAmount(1234, withSign: true) == "+¥12.34")
        #expect(formatAmount(0) == "¥0.00")
    }
}
```

- [x] **Step 2: 跑测试确认失败**（`cannot find 'MoneyAmount' in scope`）

- [x] **Step 3: 实现**

```swift
// zanzan/Shared/MoneyFormatter.swift
import Foundation

/// 金额分↔元换算唯一入口（设计文档 §4：全库不允许第二种实现）。
enum MoneyAmount {
    /// "12.34" → 1234；空串/非法/负数/超两位小数返回 nil。
    static func minorUnits(fromDecimalString string: String) -> Int? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-"),
              let decimal = Decimal(string: trimmed, locale: Locale(identifier: "en_US")) else { return nil }
        var scaled = decimal * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded == scaled else { return nil } // 超两位小数
        return (rounded as NSDecimalNumber).intValue
    }

    /// 允许负号的换算（账户期初余额等有符号场景）。
    static func signedMinorUnits(fromDecimalString string: String) -> Int? {
        var trimmed = string.trimmingCharacters(in: .whitespaces)
        var isNegative = false
        if trimmed.hasPrefix("-") {
            isNegative = true
            trimmed.removeFirst()
        }
        guard let magnitude = minorUnits(fromDecimalString: trimmed) else { return nil }
        return isNegative ? -magnitude : magnitude
    }

    /// 表单回填用十进制串（无货币符号，尾零自然省略）。
    static func decimalString(fromMinorUnits minorUnits: Int) -> String {
        "\(Decimal(minorUnits) / 100)"
    }
}

/// 金额展示格式化唯一入口（设计文档 §4）。本位币锁 CNY、locale 锁 zh_CN（测试确定性）。
func formatAmount(_ minorUnits: Int, withSign: Bool = false) -> String {
    let decimal = Decimal(minorUnits) / 100
    let core = decimal.formatted(.currency(code: "CNY").locale(Locale(identifier: "zh_CN")))
    if withSign && minorUnits > 0 { return "+\(core)" }
    return core
}
```

- [x] **Step 4: 跑测试确认通过**
- [x] **Step 5: Commit** `✨ feat(shared): 金额换算与展示格式化唯一入口`

---

### Task 2: LedgerDraft + LedgerCommands

**Files:**
- Create: `zanzan/Core/Drafts/LedgerDraft.swift`
- Create: `zanzan/Core/Commands/LedgerCommands.swift`
- Test: `zanzanTests/LedgerCommandsTests.swift`

**Interfaces:**
- Consumes: `StoredLedger` / `StoredTransaction` / `StoredBudget` 模型。
- Produces: `LedgerDraft { name, colorID; validated() throws -> LedgerDraft }`、`LedgerCommands(context:)` 的 `createLedger(_:) -> StoredLedger`（首本自动 `isDefault`）、`updateLedger(uuid:draft:)`、`setDefaultLedger(uuid:)`（唯一性）、`softDeleteLedger(uuid:)`（默认账本禁删、有活跃流水阻断、级联软删预算）；`LedgerDraftError` / `LedgerCommandError`。

- [x] **Step 1: 写失败测试**

```swift
// zanzanTests/LedgerCommandsTests.swift
import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct LedgerCommandsTests {
    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    @Test func 空名草稿被拒() throws {
        #expect(throws: LedgerDraftError.self) {
            _ = try LedgerDraft(name: "  ").validated()
        }
    }

    @Test func 首本自动成为默认账本() throws {
        let context = try makeContext()
        let commands = LedgerCommands(context: context)
        let first = try commands.createLedger(LedgerDraft(name: "日常"))
        let second = try commands.createLedger(LedgerDraft(name: "旅行"))
        #expect(first.isDefault)
        #expect(!second.isDefault)
        #expect(second.sortOrder == 1)
    }

    @Test func 设默认清除旧默认() throws {
        let context = try makeContext()
        let commands = LedgerCommands(context: context)
        let first = try commands.createLedger(LedgerDraft(name: "日常"))
        let second = try commands.createLedger(LedgerDraft(name: "旅行"))
        try commands.setDefaultLedger(uuid: second.uuid)
        #expect(!first.isDefault)
        #expect(second.isDefault)
    }

    @Test func 默认账本禁删() throws {
        let context = try makeContext()
        let commands = LedgerCommands(context: context)
        let ledger = try commands.createLedger(LedgerDraft(name: "日常"))
        #expect(throws: LedgerCommandError.self) {
            try commands.softDeleteLedger(uuid: ledger.uuid)
        }
    }

    @Test func 有活跃流水阻断删除() throws {
        let context = try makeContext()
        let commands = LedgerCommands(context: context)
        _ = try commands.createLedger(LedgerDraft(name: "日常"))
        let target = try commands.createLedger(LedgerDraft(name: "旅行"))
        let tx = StoredTransaction(kind: .expense, amountMinorUnits: 100, occurredAt: .now, ledgerID: target.uuid)
        context.insert(tx)
        try context.save()
        #expect(throws: LedgerCommandError.self) {
            try commands.softDeleteLedger(uuid: target.uuid)
        }
    }

    @Test func 删除级联软删预算() throws {
        let context = try makeContext()
        let commands = LedgerCommands(context: context)
        _ = try commands.createLedger(LedgerDraft(name: "日常"))
        let target = try commands.createLedger(LedgerDraft(name: "旅行"))
        let budget = StoredBudget(ledgerID: target.uuid, amountMinorUnits: 100_000)
        context.insert(budget)
        try context.save()
        try commands.softDeleteLedger(uuid: target.uuid)
        #expect(target.isSoftDeleted)
        #expect(budget.isSoftDeleted)
    }

    @Test func 改名更新updatedAt() throws {
        let context = try makeContext()
        let commands = LedgerCommands(context: context)
        let ledger = try commands.createLedger(LedgerDraft(name: "日常"))
        let before = ledger.updatedAt
        try commands.updateLedger(uuid: ledger.uuid, draft: LedgerDraft(name: "生活"))
        #expect(ledger.name == "生活")
        #expect(ledger.updatedAt >= before)
    }
}
```

- [x] **Step 2: 跑测试确认失败**
- [x] **Step 3: 实现**

```swift
// zanzan/Core/Drafts/LedgerDraft.swift
import Foundation

/// 账本表单草稿——入口校验 + 归一化（三层防线第一层）。
struct LedgerDraft {
    var name: String = ""
    var colorID: String = "blue"

    /// 归一化（trim）并校验；非法输入 fail fast。
    func validated() throws -> LedgerDraft {
        var draft = self
        draft.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.name.isEmpty else { throw LedgerDraftError.emptyName }
        return draft
    }
}

enum LedgerDraftError: LocalizedError {
    case emptyName
    var errorDescription: String? {
        switch self {
        case .emptyName: "账本名不能为空"
        }
    }
}
```

```swift
// zanzan/Core/Commands/LedgerCommands.swift
import Foundation
import SwiftData

/// 账本写路径命令（设计文档 §4 软删语义 / 5.1）。一条命令 = 一个事务，收尾显式 save()。
struct LedgerCommands {
    let context: ModelContext

    @discardableResult
    func createLedger(_ draft: LedgerDraft) throws -> StoredLedger {
        let draft = try draft.validated()
        let activeCount = try context.fetchCount(
            FetchDescriptor<StoredLedger>(predicate: #Predicate { !$0.isSoftDeleted })
        )
        let ledger = StoredLedger(name: draft.name)
        ledger.colorID = draft.colorID
        ledger.isDefault = activeCount == 0 // 首本即默认（有且仅有一本默认，命令层保证）
        ledger.sortOrder = activeCount
        context.insert(ledger)
        try context.save()
        return ledger
    }

    func updateLedger(uuid: UUID, draft: LedgerDraft) throws {
        let draft = try draft.validated()
        let ledger = try fetchActiveLedger(uuid)
        ledger.name = draft.name
        ledger.colorID = draft.colorID
        ledger.updatedAt = .now
        try context.save()
    }

    func setDefaultLedger(uuid: UUID) throws {
        let target = try fetchActiveLedger(uuid)
        let actives = try context.fetch(
            FetchDescriptor<StoredLedger>(predicate: #Predicate { !$0.isSoftDeleted })
        )
        for ledger in actives where ledger.isDefault && ledger.uuid != uuid {
            ledger.isDefault = false
            ledger.updatedAt = .now
        }
        target.isDefault = true
        target.updatedAt = .now
        try context.save()
    }

    /// 软删：默认账本禁删；有活跃流水阻断并引导归档；级联软删该账本预算。
    func softDeleteLedger(uuid: UUID) throws {
        let ledger = try fetchActiveLedger(uuid)
        guard !ledger.isDefault else { throw LedgerCommandError.cannotDeleteDefault }
        let ledgerID: UUID? = uuid
        let activeTransactionCount = try context.fetchCount(
            FetchDescriptor<StoredTransaction>(predicate: #Predicate { !$0.isSoftDeleted && $0.ledgerID == ledgerID })
        )
        guard activeTransactionCount == 0 else { throw LedgerCommandError.hasActiveTransactions }
        ledger.isSoftDeleted = true
        ledger.updatedAt = .now
        let budgets = try context.fetch(
            FetchDescriptor<StoredBudget>(predicate: #Predicate { !$0.isSoftDeleted && $0.ledgerID == uuid })
        )
        for budget in budgets {
            budget.isSoftDeleted = true
            budget.updatedAt = .now
        }
        try context.save()
    }

    private func fetchActiveLedger(_ uuid: UUID) throws -> StoredLedger {
        let descriptor = FetchDescriptor<StoredLedger>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        )
        guard let ledger = try context.fetch(descriptor).first else {
            throw LedgerCommandError.ledgerNotFound
        }
        return ledger
    }
}

enum LedgerCommandError: LocalizedError {
    case ledgerNotFound
    case cannotDeleteDefault
    case hasActiveTransactions

    var errorDescription: String? {
        switch self {
        case .ledgerNotFound: "账本不存在或已删除"
        case .cannotDeleteDefault: "默认账本不能删除，请先把其他账本设为默认"
        case .hasActiveTransactions: "账本内还有流水，无法删除；可先归档或迁移流水"
        }
    }
}
```

- [x] **Step 4: 跑测试确认通过**
- [x] **Step 5: Commit** `✨ feat(core): 账本草稿校验与写路径命令`

---

### Task 3: DefaultDataSeeder 首启种子 + App 接线

**Files:**
- Create: `zanzan/Core/Commands/DefaultDataSeeder.swift`
- Modify: `zanzan/App/ZanzanApp.swift`
- Test: `zanzanTests/DefaultDataSeederTests.swift`

**Interfaces:**
- Consumes: `LedgerCommands.createLedger(_:)`；`StoredAccount` / `StoredCategory` / `StoredMeta` 模型。
- Produces: `DefaultDataSeeder(context:).seedIfNeeded()`（幂等，完成标记 `StoredMeta` key `dataMigration.defaultSeed`）；种子 = 默认账本「日常账本」+ 默认账户「现金」（fund）+ 全局两级分类树（支出 8 个一级含餐饮 4 子类、收入 4 个一级），分类全部 `isBuiltIn = true`、`iconKindRawValue = "symbol"`。

- [x] **Step 1: 写失败测试**

```swift
// zanzanTests/DefaultDataSeederTests.swift
import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct DefaultDataSeederTests {
    @Test func 首启写入默认账本账户与两级分类() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        try DefaultDataSeeder(context: context).seedIfNeeded()

        let ledgers = try context.fetch(FetchDescriptor<StoredLedger>())
        #expect(ledgers.count == 1)
        #expect(ledgers.first?.isDefault == true)

        let accounts = try context.fetch(FetchDescriptor<StoredAccount>())
        #expect(accounts.count == 1)
        #expect(accounts.first?.kind == .fund)

        let categories = try context.fetch(FetchDescriptor<StoredCategory>())
        #expect(categories.allSatisfy(\.isBuiltIn))
        #expect(categories.allSatisfy { $0.ledgerID == nil }) // 全局分类
        let expenseRoots = categories.filter { $0.kind == .expense && $0.parentID == nil }
        let incomeRoots = categories.filter { $0.kind == .income && $0.parentID == nil }
        #expect(expenseRoots.count == 8)
        #expect(incomeRoots.count == 4)
        // 两级树：餐饮下有子类且 parentID 正确
        let dining = try #require(expenseRoots.first { $0.name == "餐饮" })
        let children = categories.filter { $0.parentID == dining.uuid }
        #expect(children.count == 4)
    }

    @Test func 幂等重跑不产生重复() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let seeder = DefaultDataSeeder(context: context)
        try seeder.seedIfNeeded()
        let firstCount = try context.fetch(FetchDescriptor<StoredCategory>()).count
        try seeder.seedIfNeeded()
        #expect(try context.fetch(FetchDescriptor<StoredCategory>()).count == firstCount)
        #expect(try context.fetch(FetchDescriptor<StoredLedger>()).count == 1)
        let key = DefaultDataSeeder.completionKey
        let metas = try context.fetch(FetchDescriptor<StoredMeta>(predicate: #Predicate { $0.key == key }))
        #expect(metas.count == 1)
    }
}
```

- [x] **Step 2: 跑测试确认失败**
- [x] **Step 3: 实现**

```swift
// zanzan/Core/Commands/DefaultDataSeeder.swift
import Foundation
import SwiftData

/// 首启种子（设计文档 §4）：幂等写入默认账本、默认账户、默认两级分类；
/// 完成标记走 StoredMeta dataMigration.* 惯例（13.3 幂等命令迁移同款机制）。
struct DefaultDataSeeder {
    static let completionKey = "dataMigration.defaultSeed"

    let context: ModelContext

    func seedIfNeeded() throws {
        let key = Self.completionKey
        let doneCount = try context.fetchCount(
            FetchDescriptor<StoredMeta>(predicate: #Predicate { $0.key == key })
        )
        guard doneCount == 0 else { return }

        try LedgerCommands(context: context).createLedger(LedgerDraft(name: "日常账本"))

        let cash = StoredAccount(name: "现金", kind: .fund)
        cash.iconKindRawValue = StoredIconDescriptor.Kind.symbol.rawValue
        cash.iconPrimary = "banknote"
        context.insert(cash)

        seedCategories(kind: .expense, tree: Self.expenseTree)
        seedCategories(kind: .income, tree: Self.incomeTree)

        context.insert(StoredMeta(key: key, value: "done"))
        try context.save()
    }

    // MARK: - 种子数据

    private struct SeedCategory {
        let name: String
        let symbol: String
        var children: [(name: String, symbol: String)] = []
    }

    private static let expenseTree: [SeedCategory] = [
        SeedCategory(name: "餐饮", symbol: "fork.knife", children: [
            ("早餐", "sunrise"), ("午餐", "sun.max"), ("晚餐", "moon"), ("饮料零食", "cup.and.saucer"),
        ]),
        SeedCategory(name: "交通", symbol: "car"),
        SeedCategory(name: "购物", symbol: "cart"),
        SeedCategory(name: "居住", symbol: "house"),
        SeedCategory(name: "娱乐", symbol: "gamecontroller"),
        SeedCategory(name: "医疗", symbol: "cross.case"),
        SeedCategory(name: "人情", symbol: "gift"),
        SeedCategory(name: "其他", symbol: "ellipsis.circle"),
    ]

    private static let incomeTree: [SeedCategory] = [
        SeedCategory(name: "工资", symbol: "banknote"),
        SeedCategory(name: "奖金", symbol: "star"),
        SeedCategory(name: "理财收益", symbol: "chart.line.uptrend.xyaxis"),
        SeedCategory(name: "其他收入", symbol: "tray.and.arrow.down"),
    ]

    private func seedCategories(kind: TransactionKind, tree: [SeedCategory]) {
        for (index, seed) in tree.enumerated() {
            let parent = makeCategory(name: seed.name, symbol: seed.symbol, kind: kind, sortOrder: index)
            context.insert(parent)
            for (childIndex, child) in seed.children.enumerated() {
                let category = makeCategory(name: child.name, symbol: child.symbol, kind: kind, sortOrder: childIndex)
                category.parentID = parent.uuid
                context.insert(category)
            }
        }
    }

    private func makeCategory(name: String, symbol: String, kind: TransactionKind, sortOrder: Int) -> StoredCategory {
        let category = StoredCategory(name: name, kind: kind, sortOrder: sortOrder)
        category.iconKindRawValue = StoredIconDescriptor.Kind.symbol.rawValue
        category.iconPrimary = symbol
        category.isBuiltIn = true
        return category
    }
}
```

```swift
// zanzan/App/ZanzanApp.swift（修改 init）
init() {
    do {
        container = try AppModelContainer.make()
        try DefaultDataSeeder(context: container.mainContext).seedIfNeeded()
    } catch {
        // 本地库创建/种子失败无降级路径：带上下文崩溃优于静默空转。
        fatalError("无法初始化数据库：\(error)")
    }
}
```

- [x] **Step 4: 跑测试确认通过**
- [x] **Step 5: Commit** `✨ feat(core): 首启种子幂等写入默认账本账户与分类`

---

### Task 4: 账本管理 UI + 我的页入口

**Files:**
- Create: `zanzan/Features/Ledgers/LedgersListView.swift`
- Create: `zanzan/Features/Ledgers/LedgerFormView.swift`
- Modify: `zanzan/Features/Settings/SettingsHomeView.swift`

**Interfaces:**
- Consumes: `LedgerDraft` / `LedgerCommands`。
- Produces: `LedgersListView`（列表 + 新建/编辑 sheet + 设默认/删除 swipe）、`LedgerFormView(title:draft:onSave:)`、`SettingsRoute`（`.ledgers` / `.accounts`，Task 7 复用）。`AccountsListView` 在 Task 7 才建，本任务先让 `.accounts` 分支指向 `ContentUnavailableView("账户管理开发中", systemImage: "creditcard")` 占位，Task 7 替换。

- [x] **Step 1: 实现三个视图**

```swift
// zanzan/Features/Settings/SettingsHomeView.swift（整文件替换）
import SwiftUI

enum SettingsRoute: Hashable {
    case ledgers
    case accounts
}

struct SettingsHomeView: View {
    var body: some View {
        List {
            Section("数据") {
                NavigationLink("账本管理", value: SettingsRoute.ledgers)
                NavigationLink("账户管理", value: SettingsRoute.accounts)
            }
        }
        .navigationTitle("我的")
        .navigationDestination(for: SettingsRoute.self) { route in
            switch route {
            case .ledgers: LedgersListView()
            case .accounts: ContentUnavailableView("账户管理开发中", systemImage: "creditcard")
            }
        }
    }
}

#Preview {
    NavigationStack { SettingsHomeView() }
}
```

```swift
// zanzan/Features/Ledgers/LedgersListView.swift
import SwiftData
import SwiftUI

/// 账本管理（我的 → 账本管理）。静态谓词 @Query；写操作全走 LedgerCommands。
struct LedgersListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<StoredLedger> { !$0.isSoftDeleted }, sort: \StoredLedger.sortOrder)
    private var ledgers: [StoredLedger]

    @State private var isAddingLedger = false
    @State private var editingLedger: StoredLedger?
    @State private var commandErrorMessage: String?

    var body: some View {
        List {
            ForEach(ledgers) { ledger in
                Button {
                    editingLedger = ledger
                } label: {
                    HStack {
                        Text(ledger.name)
                        Spacer()
                        if ledger.isDefault {
                            Text("默认").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .tint(.primary)
                .swipeActions(edge: .trailing) {
                    Button("删除", systemImage: "trash", role: .destructive) {
                        run { try LedgerCommands(context: modelContext).softDeleteLedger(uuid: ledger.uuid) }
                    }
                    if !ledger.isDefault {
                        Button("设为默认", systemImage: "checkmark.circle") {
                            run { try LedgerCommands(context: modelContext).setDefaultLedger(uuid: ledger.uuid) }
                        }
                    }
                }
            }
        }
        .navigationTitle("账本管理")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("新建账本", systemImage: "plus") { isAddingLedger = true }
            }
        }
        .sheet(isPresented: $isAddingLedger) {
            LedgerFormView(title: "新建账本", draft: LedgerDraft()) { draft in
                try LedgerCommands(context: modelContext).createLedger(draft)
            }
        }
        .sheet(item: $editingLedger) { ledger in
            LedgerFormView(title: "编辑账本", draft: LedgerDraft(name: ledger.name, colorID: ledger.colorID)) { draft in
                try LedgerCommands(context: modelContext).updateLedger(uuid: ledger.uuid, draft: draft)
            }
        }
        .alert("操作失败", isPresented: isPresentingError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(commandErrorMessage ?? "")
        }
    }

    private var isPresentingError: Binding<Bool> {
        Binding(
            get: { commandErrorMessage != nil },
            set: { if !$0 { commandErrorMessage = nil } }
        )
    }

    private func run(_ command: () throws -> Void) {
        do { try command() } catch { commandErrorMessage = error.localizedDescription }
    }
}
```

```swift
// zanzan/Features/Ledgers/LedgerFormView.swift
import SwiftUI

/// 账本新建/编辑表单；Draft 校验错误内联展示（三层防线第一层落 UI）。
struct LedgerFormView: View {
    let title: String
    @State var draft: LedgerDraft
    let onSave: (LedgerDraft) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("账本名", text: $draft.name)
                if let validationMessage {
                    Text(validationMessage).font(.footnote).foregroundStyle(.red)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
        }
    }

    private func save() {
        do {
            try onSave(draft)
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}
```

- [x] **Step 2: 编译 + 全量单测确认绿**（UI 无单测，构建即验证）
- [x] **Step 3: Commit** `✨ feat(ledgers): 账本管理列表与表单接入我的页`

---

### Task 5: AccountDraft + AccountCommands

**Files:**
- Create: `zanzan/Core/Drafts/AccountDraft.swift`
- Create: `zanzan/Core/Commands/AccountCommands.swift`
- Test: `zanzanTests/AccountCommandsTests.swift`

**Interfaces:**
- Consumes: `MoneyAmount.signedMinorUnits` / `minorUnits`；`StoredAccount` / `StoredTransaction` / `StoredBalanceSnapshot`。
- Produces: `AccountDraft`（字段 `name/subtitle/kind/initialBalanceString/creditLimitString/statementDay/paymentDueDay/note/isIncludedInNetWorth`；`validated() -> AccountDraft.Validated`——非 credit 类清空信用字段、账单/还款日 1...28）；`AccountCommands(context:)` 的 `createAccount(_:) -> StoredAccount`、`updateAccount(uuid:draft:)`、`setArchived(uuid:isArchived:)`、`softDeleteAccount(uuid:)`（活跃流水引用阻断——含转入方引用；级联软删余额快照）。

- [x] **Step 1: 写失败测试**

```swift
// zanzanTests/AccountCommandsTests.swift
import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct AccountCommandsTests {
    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    @Test func 创建账户解析期初余额() throws {
        let context = try makeContext()
        var draft = AccountDraft()
        draft.name = "招行储蓄卡"
        draft.subtitle = "招商银行"
        draft.kind = .fund
        draft.initialBalanceString = "1234.56"
        let account = try AccountCommands(context: context).createAccount(draft)
        #expect(account.initialBalanceMinorUnits == 123_456)
        #expect(account.kind == .fund)
        #expect(account.currencyCode == "CNY")
    }

    @Test func 期初余额允许负数() throws {
        let context = try makeContext()
        var draft = AccountDraft()
        draft.name = "信用卡"
        draft.kind = .credit
        draft.initialBalanceString = "-500"
        let account = try AccountCommands(context: context).createAccount(draft)
        #expect(account.initialBalanceMinorUnits == -50_000)
    }

    @Test func 非credit类清空信用字段() throws {
        var draft = AccountDraft()
        draft.name = "现金"
        draft.kind = .fund
        draft.creditLimitString = "10000"
        draft.statementDay = 5
        draft.paymentDueDay = 25
        let validated = try draft.validated()
        #expect(validated.creditLimitMinorUnits == nil)
        #expect(validated.statementDay == nil)
        #expect(validated.paymentDueDay == nil)
    }

    @Test func 账单日越界被拒() throws {
        var draft = AccountDraft()
        draft.name = "信用卡"
        draft.kind = .credit
        draft.statementDay = 29
        #expect(throws: AccountDraftError.self) { _ = try draft.validated() }
    }

    @Test func 空名被拒() throws {
        var draft = AccountDraft()
        draft.name = " "
        #expect(throws: AccountDraftError.self) { _ = try draft.validated() }
    }

    @Test func 有活跃流水引用阻断删除含转入方() throws {
        let context = try makeContext()
        let commands = AccountCommands(context: context)
        var draft = AccountDraft()
        draft.name = "现金"
        let source = try commands.createAccount(draft)
        draft.name = "储蓄卡"
        let target = try commands.createAccount(draft)
        let tx = StoredTransaction(kind: .transfer, amountMinorUnits: 100, occurredAt: .now, ledgerID: UUID())
        tx.account = source
        tx.targetAccount = target
        context.insert(tx)
        try context.save()
        #expect(throws: AccountCommandError.self) { try commands.softDeleteAccount(uuid: source.uuid) }
        #expect(throws: AccountCommandError.self) { try commands.softDeleteAccount(uuid: target.uuid) }
    }

    @Test func 删除级联软删余额快照() throws {
        let context = try makeContext()
        let commands = AccountCommands(context: context)
        var draft = AccountDraft()
        draft.name = "现金"
        let account = try commands.createAccount(draft)
        let snapshot = StoredBalanceSnapshot(accountID: account.uuid, snapshotAt: .now, balanceMinorUnits: 100)
        context.insert(snapshot)
        try context.save()
        try commands.softDeleteAccount(uuid: account.uuid)
        #expect(account.isSoftDeleted)
        #expect(snapshot.isSoftDeleted)
    }

    @Test func 归档切换() throws {
        let context = try makeContext()
        let commands = AccountCommands(context: context)
        var draft = AccountDraft()
        draft.name = "公积金"
        let account = try commands.createAccount(draft)
        try commands.setArchived(uuid: account.uuid, isArchived: true)
        #expect(account.isArchived)
        try commands.setArchived(uuid: account.uuid, isArchived: false)
        #expect(!account.isArchived)
    }
}
```

- [x] **Step 2: 跑测试确认失败**
- [x] **Step 3: 实现**

```swift
// zanzan/Core/Drafts/AccountDraft.swift
import Foundation

/// 账户表单草稿——入口校验 + 归一化。信用字段仅 credit 类保留（设计文档 5.2）。
struct AccountDraft {
    var name: String = ""
    var subtitle: String = ""
    var kind: AccountKind = .fund
    var initialBalanceString: String = "0"
    var creditLimitString: String = ""
    var statementDay: Int? = nil
    var paymentDueDay: Int? = nil
    var note: String = ""
    var isIncludedInNetWorth: Bool = true

    struct Validated {
        let name: String
        let subtitle: String
        let kind: AccountKind
        let initialBalanceMinorUnits: Int
        let creditLimitMinorUnits: Int?
        let statementDay: Int?
        let paymentDueDay: Int?
        let note: String
        let isIncludedInNetWorth: Bool
    }

    func validated() throws -> Validated {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AccountDraftError.emptyName }
        guard let initialBalance = MoneyAmount.signedMinorUnits(fromDecimalString: initialBalanceString) else {
            throw AccountDraftError.invalidInitialBalance
        }
        // 非 credit 类归一化清空信用字段（表单只对 credit 展示这些字段）
        var creditLimit: Int? = nil
        var statementDay: Int? = nil
        var paymentDueDay: Int? = nil
        if kind == .credit {
            if !creditLimitString.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let limit = MoneyAmount.minorUnits(fromDecimalString: creditLimitString) else {
                    throw AccountDraftError.invalidCreditLimit
                }
                creditLimit = limit
            }
            statementDay = self.statementDay
            paymentDueDay = self.paymentDueDay
            for day in [statementDay, paymentDueDay].compactMap({ $0 }) {
                guard (1...28).contains(day) else { throw AccountDraftError.invalidDayOfMonth }
            }
        }
        return Validated(
            name: name,
            subtitle: subtitle.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            initialBalanceMinorUnits: initialBalance,
            creditLimitMinorUnits: creditLimit,
            statementDay: statementDay,
            paymentDueDay: paymentDueDay,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            isIncludedInNetWorth: isIncludedInNetWorth
        )
    }
}

enum AccountDraftError: LocalizedError {
    case emptyName
    case invalidInitialBalance
    case invalidCreditLimit
    case invalidDayOfMonth

    var errorDescription: String? {
        switch self {
        case .emptyName: "账户名不能为空"
        case .invalidInitialBalance: "期初余额格式不正确"
        case .invalidCreditLimit: "信用额度格式不正确"
        case .invalidDayOfMonth: "账单日/还款日须在 1–28 之间"
        }
    }
}
```

```swift
// zanzan/Core/Commands/AccountCommands.swift
import Foundation
import SwiftData

/// 账户写路径命令（设计文档 §4 软删语义 / 5.2）。
struct AccountCommands {
    let context: ModelContext

    @discardableResult
    func createAccount(_ draft: AccountDraft) throws -> StoredAccount {
        let v = try draft.validated()
        let activeCount = try context.fetchCount(
            FetchDescriptor<StoredAccount>(predicate: #Predicate { !$0.isSoftDeleted })
        )
        let account = StoredAccount(name: v.name, kind: v.kind)
        apply(v, to: account)
        account.sortOrder = activeCount
        context.insert(account)
        try context.save()
        return account
    }

    func updateAccount(uuid: UUID, draft: AccountDraft) throws {
        let v = try draft.validated()
        let account = try fetchActiveAccount(uuid)
        account.kindRawValue = v.kind.rawValue
        apply(v, to: account)
        account.updatedAt = .now
        try context.save()
    }

    func setArchived(uuid: UUID, isArchived: Bool) throws {
        let account = try fetchActiveAccount(uuid)
        account.isArchived = isArchived
        account.updatedAt = .now
        try context.save()
    }

    /// 软删：任何活跃流水引用（收支/转出/转入）都阻断并引导归档；级联软删余额快照。
    func softDeleteAccount(uuid: UUID) throws {
        let account = try fetchActiveAccount(uuid)
        let referenceCount = try context.fetchCount(
            FetchDescriptor<StoredTransaction>(predicate: #Predicate {
                !$0.isSoftDeleted && ($0.account?.uuid == uuid || $0.targetAccount?.uuid == uuid)
            })
        )
        guard referenceCount == 0 else { throw AccountCommandError.hasActiveTransactions }
        account.isSoftDeleted = true
        account.updatedAt = .now
        let snapshots = try context.fetch(
            FetchDescriptor<StoredBalanceSnapshot>(predicate: #Predicate { !$0.isSoftDeleted && $0.accountID == uuid })
        )
        for snapshot in snapshots {
            snapshot.isSoftDeleted = true
            snapshot.updatedAt = .now
        }
        try context.save()
    }

    private func apply(_ v: AccountDraft.Validated, to account: StoredAccount) {
        account.name = v.name
        account.subtitle = v.subtitle
        account.initialBalanceMinorUnits = v.initialBalanceMinorUnits
        account.creditLimitMinorUnits = v.creditLimitMinorUnits
        account.statementDay = v.statementDay
        account.paymentDueDay = v.paymentDueDay
        account.note = v.note
        account.isIncludedInNetWorth = v.isIncludedInNetWorth
    }

    private func fetchActiveAccount(_ uuid: UUID) throws -> StoredAccount {
        let descriptor = FetchDescriptor<StoredAccount>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        )
        guard let account = try context.fetch(descriptor).first else {
            throw AccountCommandError.accountNotFound
        }
        return account
    }
}

enum AccountCommandError: LocalizedError {
    case accountNotFound
    case hasActiveTransactions

    var errorDescription: String? {
        switch self {
        case .accountNotFound: "账户不存在或已删除"
        case .hasActiveTransactions: "账户名下还有流水，无法删除；可先归档或转移流水"
        }
    }
}
```

- [x] **Step 4: 跑测试确认通过**
- [x] **Step 5: Commit** `✨ feat(core): 账户草稿校验与写路径命令`

---

### Task 6: AccountBalanceProjector 余额派生

**Files:**
- Create: `zanzan/Core/Projections/AccountBalanceProjector.swift`
- Test: `zanzanTests/AccountBalanceProjectorTests.swift`
- Modify（补测试债）: `zanzanTests/TransactionDerivationTests.swift` 若缺 `income − fee` 断言则补一条

**Interfaces:**
- Consumes: `StoredTransaction.balanceDeltaMinorUnits(for:)`（fee 恒为流出口径）。
- Produces: `AccountBalanceProjector(context:).balanceMinorUnits(of: StoredAccount) throws -> Int`（期初 + Σ 活跃流水 delta，谓词下推双向账户引用）。

- [x] **Step 1: 写失败测试**

```swift
// zanzanTests/AccountBalanceProjectorTests.swift
import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct AccountBalanceProjectorTests {
    @Test func 余额等于期初加流水派生() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let ledgerID = UUID()
        let cash = StoredAccount(name: "现金", kind: .fund)
        cash.initialBalanceMinorUnits = 10_000
        let card = StoredAccount(name: "储蓄卡", kind: .fund)
        context.insert(cash)
        context.insert(card)

        let expense = StoredTransaction(kind: .expense, amountMinorUnits: 1_000, occurredAt: .now, ledgerID: ledgerID)
        expense.account = cash
        let income = StoredTransaction(kind: .income, amountMinorUnits: 5_000, occurredAt: .now, ledgerID: ledgerID)
        income.account = cash
        income.feeMinorUnits = 100 // income − fee 口径
        let transfer = StoredTransaction(kind: .transfer, amountMinorUnits: 2_000, occurredAt: .now, ledgerID: ledgerID)
        transfer.account = cash
        transfer.targetAccount = card
        transfer.feeMinorUnits = 50
        let deleted = StoredTransaction(kind: .expense, amountMinorUnits: 9_999, occurredAt: .now, ledgerID: ledgerID)
        deleted.account = cash
        deleted.isSoftDeleted = true // 软删流水不计
        for tx in [expense, income, transfer, deleted] { context.insert(tx) }
        try context.save()

        let projector = AccountBalanceProjector(context: context)
        // 现金：10000 − 1000 + (5000−100) − (2000+50) = 11850
        #expect(try projector.balanceMinorUnits(of: cash) == 11_850)
        // 储蓄卡：0 + 2000 = 2000
        #expect(try projector.balanceMinorUnits(of: card) == 2_000)
    }
}
```

- [x] **Step 2: 跑测试确认失败**
- [x] **Step 3: 实现**

```swift
// zanzan/Core/Projections/AccountBalanceProjector.swift
import Foundation
import SwiftData

/// 账户余额派生（设计文档 §4 派生优先：余额不落库）。
/// ponytail: 全量流水求和，账户流水到万条量级再上 StoredBalanceSnapshot 检查点加速。
struct AccountBalanceProjector {
    let context: ModelContext

    func balanceMinorUnits(of account: StoredAccount) throws -> Int {
        let uuid = account.uuid
        let descriptor = FetchDescriptor<StoredTransaction>(
            predicate: #Predicate {
                !$0.isSoftDeleted && ($0.account?.uuid == uuid || $0.targetAccount?.uuid == uuid)
            }
        )
        let transactions = try context.fetch(descriptor)
        return transactions.reduce(account.initialBalanceMinorUnits) {
            $0 + $1.balanceDeltaMinorUnits(for: uuid)
        }
    }
}
```

- [x] **Step 4: 跑测试确认通过**
- [x] **Step 5: Commit** `✨ feat(core): 账户余额派生投影器`

---

### Task 7: 账户管理 UI

**Files:**
- Create: `zanzan/Features/Accounts/AccountKind+Display.swift`
- Create: `zanzan/Features/Accounts/AccountsListView.swift`
- Create: `zanzan/Features/Accounts/AccountFormView.swift`
- Modify: `zanzan/Features/Settings/SettingsHomeView.swift`（`.accounts` 占位替换为 `AccountsListView()`）

**Interfaces:**
- Consumes: `AccountDraft` / `AccountCommands` / `AccountBalanceProjector` / `formatAmount`。
- Produces: `AccountsListView`（按 kind 分组 + 已归档区 + 余额展示）、`AccountFormView(title:draft:onSave:)`、`AccountKind.displayName` / `AccountKind.symbolName`。

- [x] **Step 1: 实现**

```swift
// zanzan/Features/Accounts/AccountKind+Display.swift
import Foundation

/// 账户大类展示文案与默认图标（UI 层文案，不入 Core）。
extension AccountKind {
    var displayName: String {
        switch self {
        case .fund: "资金"
        case .credit: "信用"
        case .prepaid: "充值"
        case .investment: "理财"
        case .receivable: "应收"
        case .payable: "应付"
        }
    }

    var symbolName: String {
        switch self {
        case .fund: "banknote"
        case .credit: "creditcard"
        case .prepaid: "giftcard"
        case .investment: "chart.line.uptrend.xyaxis"
        case .receivable: "tray.and.arrow.down"
        case .payable: "tray.and.arrow.up"
        }
    }
}
```

```swift
// zanzan/Features/Accounts/AccountsListView.swift
import SwiftData
import SwiftUI

/// 账户管理：按大类分组 + 已归档折叠区；余额行内派生。
struct AccountsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<StoredAccount> { !$0.isSoftDeleted }, sort: \StoredAccount.sortOrder)
    private var accounts: [StoredAccount]

    @State private var isAddingAccount = false
    @State private var editingAccount: StoredAccount?
    @State private var commandErrorMessage: String?

    private var groups: [(kind: AccountKind, accounts: [StoredAccount])] {
        let active = accounts.filter { !$0.isArchived }
        return AccountKind.allCases.compactMap { kind in
            let items = active.filter { $0.kind == kind }
            return items.isEmpty ? nil : (kind, items)
        }
    }

    private var archivedAccounts: [StoredAccount] { accounts.filter(\.isArchived) }

    var body: some View {
        List {
            ForEach(groups, id: \.kind) { group in
                Section(group.kind.displayName) {
                    ForEach(group.accounts) { account in
                        row(for: account)
                    }
                }
            }
            if !archivedAccounts.isEmpty {
                Section("已归档") {
                    ForEach(archivedAccounts) { account in
                        row(for: account)
                    }
                }
            }
        }
        .overlay {
            if accounts.isEmpty {
                ContentUnavailableView("还没有账户", systemImage: "creditcard", description: Text("点右上角添加账户"))
            }
        }
        .navigationTitle("账户管理")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("添加账户", systemImage: "plus") { isAddingAccount = true }
            }
        }
        .sheet(isPresented: $isAddingAccount) {
            AccountFormView(title: "添加账户", draft: AccountDraft()) { draft in
                try AccountCommands(context: modelContext).createAccount(draft)
            }
        }
        .sheet(item: $editingAccount) { account in
            AccountFormView(title: "编辑账户", draft: draft(from: account)) { draft in
                try AccountCommands(context: modelContext).updateAccount(uuid: account.uuid, draft: draft)
            }
        }
        .alert("操作失败", isPresented: isPresentingError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(commandErrorMessage ?? "")
        }
    }

    private func row(for account: StoredAccount) -> some View {
        Button {
            editingAccount = account
        } label: {
            HStack {
                Image(systemName: (account.kind ?? .fund).symbolName)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text(account.name)
                    if !account.subtitle.isEmpty {
                        Text(account.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(formatAmount(balanceMinorUnits(of: account)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .tint(.primary)
        .swipeActions(edge: .trailing) {
            Button("删除", systemImage: "trash", role: .destructive) {
                run { try AccountCommands(context: modelContext).softDeleteAccount(uuid: account.uuid) }
            }
            Button(account.isArchived ? "取消归档" : "归档",
                   systemImage: account.isArchived ? "tray.and.arrow.up" : "archivebox") {
                run { try AccountCommands(context: modelContext).setArchived(uuid: account.uuid, isArchived: !account.isArchived) }
            }
        }
    }

    /// ponytail: 每行一次全量求和，账户/流水量级上来再走快照缓存。
    /// 读路径自愈：投影失败回落期初余额展示，不 crash。
    private func balanceMinorUnits(of account: StoredAccount) -> Int {
        (try? AccountBalanceProjector(context: modelContext).balanceMinorUnits(of: account))
            ?? account.initialBalanceMinorUnits
    }

    private func draft(from account: StoredAccount) -> AccountDraft {
        var draft = AccountDraft()
        draft.name = account.name
        draft.subtitle = account.subtitle
        draft.kind = account.kind ?? .fund
        draft.initialBalanceString = MoneyAmount.decimalString(fromMinorUnits: account.initialBalanceMinorUnits)
        draft.creditLimitString = account.creditLimitMinorUnits.map { MoneyAmount.decimalString(fromMinorUnits: $0) } ?? ""
        draft.statementDay = account.statementDay
        draft.paymentDueDay = account.paymentDueDay
        draft.note = account.note
        draft.isIncludedInNetWorth = account.isIncludedInNetWorth
        return draft
    }

    private var isPresentingError: Binding<Bool> {
        Binding(
            get: { commandErrorMessage != nil },
            set: { if !$0 { commandErrorMessage = nil } }
        )
    }

    private func run(_ command: () throws -> Void) {
        do { try command() } catch { commandErrorMessage = error.localizedDescription }
    }
}
```

```swift
// zanzan/Features/Accounts/AccountFormView.swift
import SwiftUI

/// 账户新建/编辑表单；credit 类才展示信用字段（Draft 归一化兜底）。
struct AccountFormView: View {
    let title: String
    @State var draft: AccountDraft
    let onSave: (AccountDraft) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("账户名", text: $draft.name)
                    TextField("副标题（银行/渠道，可选）", text: $draft.subtitle)
                    Picker("类型", selection: $draft.kind) {
                        ForEach(AccountKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                }
                Section("余额") {
                    TextField("期初余额", text: $draft.initialBalanceString)
                        .keyboardType(.numbersAndPunctuation) // 需要负号，decimalPad 无
                }
                if draft.kind == .credit {
                    Section("信用") {
                        TextField("信用额度（可选）", text: $draft.creditLimitString)
                            .keyboardType(.decimalPad)
                        Picker("账单日", selection: $draft.statementDay) {
                            Text("未设置").tag(Int?.none)
                            ForEach(1...28, id: \.self) { day in
                                Text("\(day) 日").tag(Int?.some(day))
                            }
                        }
                        Picker("还款日", selection: $draft.paymentDueDay) {
                            Text("未设置").tag(Int?.none)
                            ForEach(1...28, id: \.self) { day in
                                Text("\(day) 日").tag(Int?.some(day))
                            }
                        }
                    }
                }
                Section {
                    Toggle("计入净资产", isOn: $draft.isIncludedInNetWorth)
                    TextField("备注", text: $draft.note)
                }
                if let validationMessage {
                    Text(validationMessage).font(.footnote).foregroundStyle(.red)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
        }
    }

    private func save() {
        do {
            try onSave(draft)
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}
```

SettingsHomeView `.accounts` 分支替换：

```swift
case .accounts: AccountsListView()
```

- [x] **Step 2: 编译 + 全量单测确认绿**
- [x] **Step 3: Commit** `✨ feat(accounts): 账户管理列表与表单含余额派生展示`

---

### Task 8: TransactionDraft + TransactionCommands

**Files:**
- Create: `zanzan/Core/Drafts/TransactionDraft.swift`
- Create: `zanzan/Core/Commands/TransactionCommands.swift`
- Test: `zanzanTests/TransactionCommandsTests.swift`

**Interfaces:**
- Consumes: `MoneyAmount.minorUnits`；`StoredTransaction` / `StoredAccount` / `StoredCategory` / `StoredLedger`。
- Produces: `TransactionDraft`（`kind/amountString/occurredAt/note/accountUUID/targetAccountUUID/categoryUUID/feeString`；`validated() -> TransactionDraft.Validated`——金额 > 0、收支必有账户+分类且非转账 fee 恒 0、转账必有双方且禁自转禁分类）；`TransactionCommands(context:)` 的 `recordTransaction(_:ledgerID:) -> StoredTransaction`（ledgerID 必指活跃账本、分类方向匹配、MVP 锁 CNY / fx 恒 nil）、`updateTransaction(uuid:draft:)`（kind 终生不可改写）、`softDeleteTransaction(uuid:)`、`undoSoftDeleteTransaction(uuid:)`。

- [x] **Step 1: 写失败测试**

```swift
// zanzanTests/TransactionCommandsTests.swift
import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct TransactionCommandsTests {
    /// 建好账本/账户/分类的公共夹具
    private struct Fixture {
        let context: ModelContext
        let ledger: StoredLedger
        let cash: StoredAccount
        let card: StoredAccount
        let dining: StoredCategory   // expense
        let salary: StoredCategory   // income
    }

    private func makeFixture() throws -> Fixture {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let ledger = try LedgerCommands(context: context).createLedger(LedgerDraft(name: "日常"))
        let cash = StoredAccount(name: "现金", kind: .fund)
        let card = StoredAccount(name: "储蓄卡", kind: .fund)
        let dining = StoredCategory(name: "餐饮", kind: .expense, sortOrder: 0)
        let salary = StoredCategory(name: "工资", kind: .income, sortOrder: 0)
        for model in [cash, card] as [any PersistentModel] { context.insert(model) }
        context.insert(dining)
        context.insert(salary)
        try context.save()
        return Fixture(context: context, ledger: ledger, cash: cash, card: card, dining: dining, salary: salary)
    }

    private func expenseDraft(_ f: Fixture, amount: String = "25.50") -> TransactionDraft {
        var draft = TransactionDraft()
        draft.kind = .expense
        draft.amountString = amount
        draft.accountUUID = f.cash.uuid
        draft.categoryUUID = f.dining.uuid
        return draft
    }

    @Test func 记支出流水落库() throws {
        let f = try makeFixture()
        let tx = try TransactionCommands(context: f.context).recordTransaction(expenseDraft(f), ledgerID: f.ledger.uuid)
        #expect(tx.kind == .expense)
        #expect(tx.amountMinorUnits == 2_550)
        #expect(tx.ledgerID == f.ledger.uuid)
        #expect(tx.account?.uuid == f.cash.uuid)
        #expect(tx.category?.uuid == f.dining.uuid)
        #expect(tx.feeMinorUnits == 0)          // 非转账 fee 恒 0（不变量）
        #expect(tx.currencyCode == "CNY")
        #expect(tx.fxRateToBase == nil)          // 本位币流水恒 nil
        #expect(tx.sourceKind == .manual)
    }

    @Test func 非转账草稿手续费被归零() throws {
        let f = try makeFixture()
        var draft = expenseDraft(f)
        draft.feeString = "5" // 表单不该出现，防御性归一化
        let tx = try TransactionCommands(context: f.context).recordTransaction(draft, ledgerID: f.ledger.uuid)
        #expect(tx.feeMinorUnits == 0)
    }

    @Test func ledgerID必须指向活跃账本() throws {
        let f = try makeFixture()
        #expect(throws: TransactionCommandError.self) {
            _ = try TransactionCommands(context: f.context).recordTransaction(expenseDraft(f), ledgerID: UUID())
        }
    }

    @Test func 分类方向不匹配阻断() throws {
        let f = try makeFixture()
        var draft = expenseDraft(f)
        draft.categoryUUID = f.salary.uuid // 支出挂收入分类
        #expect(throws: TransactionCommandError.self) {
            _ = try TransactionCommands(context: f.context).recordTransaction(draft, ledgerID: f.ledger.uuid)
        }
    }

    @Test func 金额非法被拒() throws {
        let f = try makeFixture()
        var draft = expenseDraft(f, amount: "0")
        #expect(throws: TransactionDraftError.self) { _ = try draft.validated() }
        draft.amountString = "abc"
        #expect(throws: TransactionDraftError.self) { _ = try draft.validated() }
    }

    @Test func 转账禁自转且必有双方() throws {
        let f = try makeFixture()
        var draft = TransactionDraft()
        draft.kind = .transfer
        draft.amountString = "100"
        draft.accountUUID = f.cash.uuid
        draft.targetAccountUUID = f.cash.uuid
        #expect(throws: TransactionDraftError.self) { _ = try draft.validated() } // 自转
        draft.targetAccountUUID = nil
        #expect(throws: TransactionDraftError.self) { _ = try draft.validated() } // 缺转入方
    }

    @Test func 转账手续费落库() throws {
        let f = try makeFixture()
        var draft = TransactionDraft()
        draft.kind = .transfer
        draft.amountString = "100"
        draft.feeString = "0.50"
        draft.accountUUID = f.cash.uuid
        draft.targetAccountUUID = f.card.uuid
        let tx = try TransactionCommands(context: f.context).recordTransaction(draft, ledgerID: f.ledger.uuid)
        #expect(tx.feeMinorUnits == 50)
        #expect(tx.targetAccount?.uuid == f.card.uuid)
        #expect(tx.category == nil) // 转账不挂分类
    }

    @Test func kind终生不可改写() throws {
        let f = try makeFixture()
        let tx = try TransactionCommands(context: f.context).recordTransaction(expenseDraft(f), ledgerID: f.ledger.uuid)
        var draft = expenseDraft(f)
        draft.kind = .income
        draft.categoryUUID = f.salary.uuid
        #expect(throws: TransactionCommandError.self) {
            try TransactionCommands(context: f.context).updateTransaction(uuid: tx.uuid, draft: draft)
        }
    }

    @Test func 编辑更新字段与updatedAt() throws {
        let f = try makeFixture()
        let commands = TransactionCommands(context: f.context)
        let tx = try commands.recordTransaction(expenseDraft(f), ledgerID: f.ledger.uuid)
        var draft = expenseDraft(f, amount: "30")
        draft.note = "改备注"
        draft.accountUUID = f.card.uuid
        try commands.updateTransaction(uuid: tx.uuid, draft: draft)
        #expect(tx.amountMinorUnits == 3_000)
        #expect(tx.note == "改备注")
        #expect(tx.account?.uuid == f.card.uuid)
    }

    @Test func 软删与撤销() throws {
        let f = try makeFixture()
        let commands = TransactionCommands(context: f.context)
        let tx = try commands.recordTransaction(expenseDraft(f), ledgerID: f.ledger.uuid)
        try commands.softDeleteTransaction(uuid: tx.uuid)
        #expect(tx.isSoftDeleted)
        try commands.undoSoftDeleteTransaction(uuid: tx.uuid)
        #expect(!tx.isSoftDeleted)
    }
}
```

- [x] **Step 2: 跑测试确认失败**
- [x] **Step 3: 实现**

```swift
// zanzan/Core/Drafts/TransactionDraft.swift
import Foundation

/// 流水表单草稿——入口校验 + 归一化（设计文档 5.4 命令层基础校验的 Draft 侧）。
struct TransactionDraft {
    var kind: TransactionKind = .expense
    var amountString: String = ""
    var occurredAt: Date = .now
    var note: String = ""
    var accountUUID: UUID? = nil
    var targetAccountUUID: UUID? = nil
    var categoryUUID: UUID? = nil
    var feeString: String = ""

    struct Validated {
        let kind: TransactionKind
        let amountMinorUnits: Int
        let occurredAt: Date
        let note: String
        let accountUUID: UUID
        let targetAccountUUID: UUID?
        let categoryUUID: UUID?
        let feeMinorUnits: Int
    }

    func validated() throws -> Validated {
        guard let amount = MoneyAmount.minorUnits(fromDecimalString: amountString), amount > 0 else {
            throw TransactionDraftError.invalidAmount
        }
        guard let accountUUID else { throw TransactionDraftError.missingAccount }
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)

        switch kind {
        case .expense, .income:
            guard let categoryUUID else { throw TransactionDraftError.missingCategory }
            // 非转账 fee 恒 0（不变量，表单不展示手续费，此处防御性归零）
            return Validated(
                kind: kind, amountMinorUnits: amount, occurredAt: occurredAt, note: note,
                accountUUID: accountUUID, targetAccountUUID: nil, categoryUUID: categoryUUID,
                feeMinorUnits: 0
            )
        case .transfer:
            guard let targetAccountUUID else { throw TransactionDraftError.missingTargetAccount }
            guard targetAccountUUID != accountUUID else { throw TransactionDraftError.sameTransferAccounts }
            let trimmedFee = feeString.trimmingCharacters(in: .whitespaces)
            var fee = 0
            if !trimmedFee.isEmpty {
                guard let parsed = MoneyAmount.minorUnits(fromDecimalString: trimmedFee) else {
                    throw TransactionDraftError.invalidFee
                }
                fee = parsed
            }
            return Validated(
                kind: kind, amountMinorUnits: amount, occurredAt: occurredAt, note: note,
                accountUUID: accountUUID, targetAccountUUID: targetAccountUUID, categoryUUID: nil,
                feeMinorUnits: fee
            )
        }
    }
}

enum TransactionDraftError: LocalizedError {
    case invalidAmount
    case missingAccount
    case missingCategory
    case missingTargetAccount
    case sameTransferAccounts
    case invalidFee

    var errorDescription: String? {
        switch self {
        case .invalidAmount: "金额须为大于 0 的数字（最多两位小数）"
        case .missingAccount: "请选择账户"
        case .missingCategory: "请选择分类"
        case .missingTargetAccount: "请选择转入账户"
        case .sameTransferAccounts: "转出与转入账户不能相同"
        case .invalidFee: "手续费格式不正确"
        }
    }
}
```

```swift
// zanzan/Core/Commands/TransactionCommands.swift
import Foundation
import SwiftData

/// 流水写路径命令（设计文档 5.4）。不变量：ledgerID 非空且活跃、分类方向匹配、
/// kind 终生不可改写、MVP 锁 CNY（fxRateToBase 恒 nil）。
struct TransactionCommands {
    let context: ModelContext

    @discardableResult
    func recordTransaction(_ draft: TransactionDraft, ledgerID: UUID) throws -> StoredTransaction {
        let v = try draft.validated()
        try ensureActiveLedger(ledgerID)
        let tx = StoredTransaction(kind: v.kind, amountMinorUnits: v.amountMinorUnits, occurredAt: v.occurredAt, ledgerID: ledgerID)
        try apply(v, to: tx)
        context.insert(tx)
        try context.save()
        return tx
    }

    func updateTransaction(uuid: UUID, draft: TransactionDraft) throws {
        let tx = try fetchTransaction(uuid, includeDeleted: false)
        guard tx.kind == draft.kind else { throw TransactionCommandError.kindImmutable }
        let v = try draft.validated()
        tx.amountMinorUnits = v.amountMinorUnits
        tx.occurredAt = v.occurredAt
        try apply(v, to: tx)
        tx.updatedAt = .now
        try context.save()
    }

    func softDeleteTransaction(uuid: UUID) throws {
        let tx = try fetchTransaction(uuid, includeDeleted: false)
        tx.isSoftDeleted = true
        tx.updatedAt = .now
        try context.save()
    }

    func undoSoftDeleteTransaction(uuid: UUID) throws {
        let tx = try fetchTransaction(uuid, includeDeleted: true)
        tx.isSoftDeleted = false
        tx.updatedAt = .now
        try context.save()
    }

    // MARK: - 私有

    private func apply(_ v: TransactionDraft.Validated, to tx: StoredTransaction) throws {
        let account = try fetchActiveAccount(v.accountUUID)
        tx.note = v.note
        tx.account = account
        tx.currencyCode = account.currencyCode // MVP 全 CNY；fxRateToBase 恒 nil
        tx.feeMinorUnits = v.feeMinorUnits
        switch v.kind {
        case .expense, .income:
            let category = try fetchActiveCategory(v.categoryUUID!)
            guard category.kind == v.kind else { throw TransactionCommandError.categoryKindMismatch }
            tx.category = category
            tx.targetAccount = nil
        case .transfer:
            tx.targetAccount = try fetchActiveAccount(v.targetAccountUUID!)
            tx.category = nil
        }
    }

    private func ensureActiveLedger(_ uuid: UUID) throws {
        let count = try context.fetchCount(
            FetchDescriptor<StoredLedger>(predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid })
        )
        guard count > 0 else { throw TransactionCommandError.ledgerNotFound }
    }

    private func fetchActiveAccount(_ uuid: UUID) throws -> StoredAccount {
        let descriptor = FetchDescriptor<StoredAccount>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        )
        guard let account = try context.fetch(descriptor).first else {
            throw TransactionCommandError.accountNotFound
        }
        return account
    }

    private func fetchActiveCategory(_ uuid: UUID) throws -> StoredCategory {
        let descriptor = FetchDescriptor<StoredCategory>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        )
        guard let category = try context.fetch(descriptor).first else {
            throw TransactionCommandError.categoryNotFound
        }
        return category
    }

    private func fetchTransaction(_ uuid: UUID, includeDeleted: Bool) throws -> StoredTransaction {
        let predicate: Predicate<StoredTransaction> = includeDeleted
            ? #Predicate { $0.uuid == uuid }
            : #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        guard let tx = try context.fetch(FetchDescriptor<StoredTransaction>(predicate: predicate)).first else {
            throw TransactionCommandError.transactionNotFound
        }
        return tx
    }
}

enum TransactionCommandError: LocalizedError {
    case ledgerNotFound
    case accountNotFound
    case categoryNotFound
    case transactionNotFound
    case categoryKindMismatch
    case kindImmutable

    var errorDescription: String? {
        switch self {
        case .ledgerNotFound: "账本不存在或已删除"
        case .accountNotFound: "账户不存在或已删除"
        case .categoryNotFound: "分类不存在或已删除"
        case .transactionNotFound: "流水不存在"
        case .categoryKindMismatch: "分类方向与流水类型不一致"
        case .kindImmutable: "流水类型不可修改，请删除后重新记一笔"
        }
    }
}
```

- [x] **Step 4: 跑测试确认通过**
- [x] **Step 5: Commit** `✨ feat(core): 流水草稿校验与写路径命令`

---

### Task 9: 明细列表（TransactionsHomeView 重写）

**Files:**
- Modify: `zanzan/Features/Transactions/TransactionsHomeView.swift`（整文件替换）
- Create: `zanzan/Features/Transactions/TransactionListView.swift`
- Create: `zanzan/Features/Transactions/TransactionRowView.swift`
- Create: `zanzan/Features/Transactions/TransactionKind+Display.swift`

**Interfaces:**
- Consumes: `TransactionCommands.softDeleteTransaction` / `formatAmount` / `StoredTransaction.signedMinorUnits`。
- Produces: `TransactionsHomeView`（默认账本归一化：`isDefault` 优先，无默认取首本活跃）、`TransactionListView(ledgerID:)`（init 参数化谓词 @Query——内嵌子视图，非 navigationDestination 目标页，不触历史教训红线）、`TransactionRowView(transaction:)`、`TransactionKind.displayName`。记一笔/编辑 sheet 挂接 Task 10 的 `TransactionFormView`；本任务先以 `EmptyView()` 占位 sheet 内容，Task 10 替换。

- [x] **Step 1: 实现**

```swift
// zanzan/Features/Transactions/TransactionKind+Display.swift
import Foundation

extension TransactionKind {
    var displayName: String {
        switch self {
        case .expense: "支出"
        case .income: "收入"
        case .transfer: "转账"
        }
    }
}
```

```swift
// zanzan/Features/Transactions/TransactionsHomeView.swift（整文件替换）
import SwiftData
import SwiftUI

/// 明细 Tab 首页：解析当前账本（默认账本归一化）后转交列表。
struct TransactionsHomeView: View {
    @Query(filter: #Predicate<StoredLedger> { !$0.isSoftDeleted }, sort: \StoredLedger.sortOrder)
    private var ledgers: [StoredLedger]

    /// 默认账本归一化（设计文档 §4 同步合并兜底样板）：优先 isDefault，违例时回落首本。
    private var currentLedger: StoredLedger? {
        ledgers.first(where: \.isDefault) ?? ledgers.first
    }

    var body: some View {
        if let ledger = currentLedger {
            TransactionListView(ledgerID: ledger.uuid)
                .navigationTitle(ledger.name)
        } else {
            ContentUnavailableView(
                "还没有账本",
                systemImage: "book.closed",
                description: Text("请到「我的 → 账本管理」创建账本")
            )
            .navigationTitle("明细")
        }
    }
}

#Preview {
    NavigationStack { TransactionsHomeView() }
}
```

```swift
// zanzan/Features/Transactions/TransactionListView.swift
import SwiftData
import SwiftUI

/// 账本内流水列表：谓词下推命中复合索引（isSoftDeleted, ledgerID, occurredAt），按天分组。
struct TransactionListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var transactions: [StoredTransaction]

    private let ledgerID: UUID
    @State private var isRecording = false
    @State private var editingTransaction: StoredTransaction?
    @State private var commandErrorMessage: String?

    init(ledgerID: UUID) {
        self.ledgerID = ledgerID
        let id: UUID? = ledgerID
        _transactions = Query(
            filter: #Predicate<StoredTransaction> { !$0.isSoftDeleted && $0.ledgerID == id },
            sort: [SortDescriptor(\StoredTransaction.occurredAt, order: .reverse)]
        )
    }

    private var dayGroups: [(day: Date, items: [StoredTransaction])] {
        Dictionary(grouping: transactions) { Calendar.current.startOfDay(for: $0.occurredAt) }
            .sorted { $0.key > $1.key }
            .map { (day: $0.key, items: $0.value) }
    }

    var body: some View {
        List {
            ForEach(dayGroups, id: \.day) { group in
                Section {
                    ForEach(group.items) { transaction in
                        Button {
                            editingTransaction = transaction
                        } label: {
                            TransactionRowView(transaction: transaction)
                        }
                        .tint(.primary)
                        .swipeActions(edge: .trailing) {
                            Button("删除", systemImage: "trash", role: .destructive) {
                                delete(transaction)
                            }
                        }
                    }
                } header: {
                    Text(group.day, format: .dateTime.month().day().weekday())
                }
            }
        }
        .overlay {
            if transactions.isEmpty {
                ContentUnavailableView(
                    "还没有流水",
                    systemImage: "list.bullet.rectangle",
                    description: Text("点右上角「记一笔」开始记账")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("记一笔", systemImage: "plus") { isRecording = true }
            }
        }
        .sheet(isPresented: $isRecording) {
            TransactionFormView(ledgerID: ledgerID)
        }
        .sheet(item: $editingTransaction) { transaction in
            TransactionFormView(ledgerID: ledgerID, editing: transaction)
        }
        .alert("操作失败", isPresented: isPresentingError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(commandErrorMessage ?? "")
        }
    }

    private func delete(_ transaction: StoredTransaction) {
        do {
            try TransactionCommands(context: modelContext).softDeleteTransaction(uuid: transaction.uuid)
        } catch {
            commandErrorMessage = error.localizedDescription
        }
    }

    private var isPresentingError: Binding<Bool> {
        Binding(
            get: { commandErrorMessage != nil },
            set: { if !$0 { commandErrorMessage = nil } }
        )
    }
}
```

```swift
// zanzan/Features/Transactions/TransactionRowView.swift
import SwiftUI

/// 流水行：分类图标 + 标题/备注 + 带符号金额。语义未知流水按「未知」降级展示。
struct TransactionRowView: View {
    let transaction: StoredTransaction

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading) {
                Text(title)
                if !transaction.note.isEmpty {
                    Text(transaction.note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(amountText)
                .foregroundStyle(amountColor)
                .monospacedDigit()
        }
    }

    private var title: String {
        switch transaction.kind {
        case .transfer:
            "\(transaction.account?.name ?? "未知账户") → \(transaction.targetAccount?.name ?? "未知账户")"
        case .expense, .income:
            transaction.category?.name ?? "未分类"
        case nil:
            "未知类型"
        }
    }

    private var iconName: String {
        switch transaction.kind {
        case .transfer: "arrow.left.arrow.right.circle"
        case .expense, .income:
            transaction.category?.iconPrimary.isEmpty == false
                ? transaction.category!.iconPrimary
                : "circle.dashed"
        case nil: "questionmark.circle"
        }
    }

    private var amountText: String {
        switch transaction.kind {
        case .transfer: formatAmount(transaction.amountMinorUnits)
        default: formatAmount(transaction.signedMinorUnits, withSign: true)
        }
    }

    private var amountColor: Color {
        switch transaction.kind {
        case .income: .green
        case .transfer: .secondary
        case .expense, nil: .primary
        }
    }
}
```

本任务内 `TransactionFormView` 尚不存在——为保编译，先在 `TransactionListView.swift` 底部加临时占位（Task 10 删除）：

```swift
// TODO(Task 10): 占位，记一笔表单在下一任务实现
struct TransactionFormView: View {
    let ledgerID: UUID
    var editing: StoredTransaction? = nil
    var body: some View { EmptyView() }
}
```

- [x] **Step 2: 编译 + 全量单测确认绿**
- [x] **Step 3: Commit** `✨ feat(transactions): 明细列表按天分组与默认账本归一化`

---

### Task 10: 记一笔/编辑表单

**Files:**
- Create: `zanzan/Features/Transactions/TransactionFormView.swift`
- Modify: `zanzan/Features/Transactions/TransactionListView.swift`（删除临时占位 struct）

**Interfaces:**
- Consumes: `TransactionDraft` / `TransactionCommands` / `MoneyAmount.decimalString` / `TransactionKind.displayName`。
- Produces: `TransactionFormView(ledgerID:editing:)`——新建/编辑共用；编辑锁 kind；分类按方向过滤两级平铺；账户过滤 `isSelectableForRecord && !isArchived`。

- [x] **Step 1: 实现**

```swift
// zanzan/Features/Transactions/TransactionFormView.swift
import SwiftData
import SwiftUI

/// 记一笔/编辑流水表单。类型 segmented；转账展示双账户 + 手续费；收支展示分类 + 账户。
struct TransactionFormView: View {
    private let ledgerID: UUID
    private let editingUUID: UUID?
    private let isKindLocked: Bool

    @State private var draft: TransactionDraft
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var validationMessage: String?

    @Query(
        filter: #Predicate<StoredAccount> { !$0.isSoftDeleted && !$0.isArchived && $0.isSelectableForRecord },
        sort: \StoredAccount.sortOrder
    )
    private var accounts: [StoredAccount]

    @Query(
        filter: #Predicate<StoredCategory> { !$0.isSoftDeleted && !$0.isArchived },
        sort: \StoredCategory.sortOrder
    )
    private var categories: [StoredCategory]

    init(ledgerID: UUID, editing transaction: StoredTransaction? = nil) {
        self.ledgerID = ledgerID
        self.editingUUID = transaction?.uuid
        self.isKindLocked = transaction != nil
        var draft = TransactionDraft()
        if let transaction {
            draft.kind = transaction.kind ?? .expense
            draft.amountString = MoneyAmount.decimalString(fromMinorUnits: transaction.amountMinorUnits)
            draft.occurredAt = transaction.occurredAt
            draft.note = transaction.note
            draft.accountUUID = transaction.account?.uuid
            draft.targetAccountUUID = transaction.targetAccount?.uuid
            draft.categoryUUID = transaction.category?.uuid
            draft.feeString = transaction.feeMinorUnits == 0
                ? ""
                : MoneyAmount.decimalString(fromMinorUnits: transaction.feeMinorUnits)
        }
        _draft = State(initialValue: draft)
    }

    /// 当前方向可选分类，两级平铺（子类缩进）。归档父类连带子类已被 @Query 过滤单层，
    /// 父类归档时子类由此再滤一道。
    private var selectableCategories: [StoredCategory] {
        let directional = categories.filter { $0.kind == draft.kind }
        let parents = directional.filter { $0.parentID == nil }
        return parents.flatMap { parent in
            [parent] + directional.filter { $0.parentID == parent.uuid }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !isKindLocked {
                    Picker("类型", selection: $draft.kind) {
                        ForEach(TransactionKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("金额", text: $draft.amountString)
                        .keyboardType(.decimalPad)
                        .font(.title2)
                }
                if draft.kind == .transfer {
                    Section("转账") {
                        accountPicker("转出账户", selection: $draft.accountUUID)
                        accountPicker("转入账户", selection: $draft.targetAccountUUID)
                        TextField("手续费（可选）", text: $draft.feeString)
                            .keyboardType(.decimalPad)
                    }
                } else {
                    Section {
                        Picker("分类", selection: $draft.categoryUUID) {
                            Text("请选择").tag(UUID?.none)
                            ForEach(selectableCategories) { category in
                                Text(category.parentID == nil ? category.name : "　\(category.name)")
                                    .tag(UUID?.some(category.uuid))
                            }
                        }
                        accountPicker("账户", selection: $draft.accountUUID)
                    }
                }
                Section {
                    DatePicker("日期", selection: $draft.occurredAt)
                    TextField("备注", text: $draft.note)
                }
                if let validationMessage {
                    Text(validationMessage).font(.footnote).foregroundStyle(.red)
                }
            }
            .navigationTitle(editingUUID == nil ? "记一笔" : "编辑流水")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .onChange(of: draft.kind) {
                draft.categoryUUID = nil // 切方向清分类，防方向不匹配
            }
            .onAppear {
                if draft.accountUUID == nil { draft.accountUUID = accounts.first?.uuid }
            }
        }
    }

    private func accountPicker(_ title: String, selection: Binding<UUID?>) -> some View {
        Picker(title, selection: selection) {
            Text("请选择").tag(UUID?.none)
            ForEach(accounts) { account in
                Text(account.name).tag(UUID?.some(account.uuid))
            }
        }
    }

    private func save() {
        do {
            let commands = TransactionCommands(context: modelContext)
            if let editingUUID {
                try commands.updateTransaction(uuid: editingUUID, draft: draft)
            } else {
                try commands.recordTransaction(draft, ledgerID: ledgerID)
            }
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}
```

同时删除 `TransactionListView.swift` 底部的临时占位 `TransactionFormView`。

- [x] **Step 2: 编译 + 全量单测确认绿**
- [x] **Step 3: Commit** `✨ feat(transactions): 记一笔与编辑流水表单`

---

### Task 11: 全量回归与收尾

- [x] **Step 1: 跑全量测试（单测 + UI 测试）**

Run: `xcodebuild test -project zanzan.xcodeproj -scheme zanzan -destination 'platform=iOS Simulator,name=iPhone 17' -quiet`
Expected: 全绿（含既有 40+ 单测与 2 条 UI 测试）。

- [x] **Step 2: 模拟器冒烟**：build & run，确认首启种子生效（明细页显示「日常账本」、我的页两个管理入口可进、账户页显示「现金」）。受模拟器验证约束（无法驱动键盘），记账主流程以单测为准，UI 以结构截图确认。

- [x] **Step 3: 计划勾选回写 + 最终提交**（若有未提交文件）`📝 docs(arch): 勾选 MVP 核心闭环计划`

## Self-Review 记录

- спec 覆盖：种子（§4 首启种子）✅ / 账本命令软删语义 ✅ / 账户信用字段与归档 ✅ / 流水 5.4 命令层基础校验 + 非转账 fee=0 + ledgerID 非空不变量 ✅ / income−fee 测试债在 Task 6 覆盖 ✅ / 默认账本归一化样板 ✅。
- 刻意砍掉（MVP 外，后续切片）：分类管理 UI、标签、附件/位置、报销退款、多币种、授信池 UI、周期记账、预算 UI、统计页、CloudKit。
- 类型一致性：`LedgerDraft.validated() -> LedgerDraft`（同型归一化）；`AccountDraft/TransactionDraft.validated() -> .Validated`（跨型，字段见各 Interfaces 块）——两种形态并存是刻意的：账本无需归一化产物类型。
