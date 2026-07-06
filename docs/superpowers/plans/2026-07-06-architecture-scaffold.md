# 主体工程架构落地 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按 `docs/superpowers/specs/2026-07-06-architecture-design.md` 落地工程骨架：命名修正、目录分层、SchemaV1 数据基座（含最小模型 `StoredLedger` 纵切验证）、ModelContainer 装配、RootView 导航壳、测试基线。

**Architecture:** 单 target + 目录分层（`App/ Core/ Features/ Shared/`），依赖方向 `Features → Core → SwiftData`；原生 SwiftUI 无 ViewModel；ModelContainer 先 `cloudKitDatabase: .none`，schema 按 CloudKit 红线建模。

**Tech Stack:** Swift 6（MainActor 默认隔离，工程已设 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`）、SwiftUI、SwiftData（`VersionedSchema` + `SchemaMigrationPlan`）、Swift Testing。

## Global Constraints

- 部署目标 iOS 27，Swift 6 语言模式；不引入任何第三方依赖、不使用 UIKit。
- CloudKit 红线（数据库文档 13.2）：全字段声明处默认值或可空；关系全可空且显式 inverse；禁 `#Unique`（非唯一 `#Index` 允许）。
- 通用基础字段（数据库文档第 4 节）：每个 `@Model` 必带 `uuid: UUID` / `isSoftDeleted: Bool = false` / `createdAt: Date` / `updatedAt: Date`。
- `Core/` 下的文件**禁止 `import SwiftUI`**。
- 事务边界：写路径显式 `modelContext.save()`（本计划只有测试里出现写路径）。
- 工程使用文件系统同步分组（`PBXFileSystemSynchronizedRootGroup`）：在 `zanzan/` 下新建/移动文件与目录**无需改 pbxproj**，Xcode 自动纳入 target；`zanzanTests/` 同理。
- 测试统一 `@testable import zanzan`，Swift Testing（`import Testing`），in-memory ModelContainer 跑真实现。
- 提交信息：gitmoji 格式 `<emoji> <type>(<scope>): <subject>`（scope 小写、header ≤72 字符），commit-msg 钩子强制校验；正文末尾空行后加 `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`。
- 构建验证命令（在仓库根执行）：
  `xcodebuild build -project zanzan.xcodeproj -scheme zanzan -destination 'generic/platform=iOS Simulator' -quiet`
- 测试验证命令（模拟器名以 `xcrun simctl list devices available | grep iPhone | head -3` 输出为准，下文以 iPhone 17 为例）：
  `xcodebuild test -project zanzan.xcodeproj -scheme zanzan -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:zanzanTests -quiet`
- 提交用 `printf ... > .git/COMMIT_EDITMSG && git commit -F .git/COMMIT_EDITMSG`（多行消息稳妥写法，见任务内示例）。

---

### Task 1: 命名修正 + App 目录

**Files:**
- Move+Modify: `zanzan/zanzanApp.swift` → `zanzan/App/ZanzanApp.swift`（类型 `zanzanApp` → `ZanzanApp`）

**Interfaces:**
- Produces: `@main struct ZanzanApp: App`（Task 3 会改它挂载容器与 RootView）

- [ ] **Step 1: 移动并改名文件**

```bash
mkdir -p zanzan/App
git mv zanzan/zanzanApp.swift zanzan/App/ZanzanApp.swift
```

- [ ] **Step 2: 修改类型名**

`zanzan/App/ZanzanApp.swift` 全文改为：

```swift
import SwiftUI

@main
struct ZanzanApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

（顺带删除 Xcode 模板生成的文件头注释；`ContentView` 在 Task 3 才被替换，此处保持引用。）

- [ ] **Step 3: 构建验证**

Run: `xcodebuild build -project zanzan.xcodeproj -scheme zanzan -destination 'generic/platform=iOS Simulator' -quiet`
Expected: 构建成功，无 error。

- [ ] **Step 4: Commit**

```bash
git add -A
printf '%s\n' '♻️ refactor(app): 修正 ZanzanApp 命名并归入 App 目录' '' '- rename zanzanApp to ZanzanApp per Swift PascalCase convention' '- move entry file into App/ directory layer' '' 'Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>' > .git/COMMIT_EDITMSG
git commit -F .git/COMMIT_EDITMSG
```

---

### Task 2: SchemaV1 数据基座（TDD）

`StoredLedger`（数据库文档 5.1）作为最小纵切模型，验证「VersionedSchema 登记簿 + 迁移计划 + 容器工厂 + in-memory 测试」整条链路。其余 14 张表属数据层阶段，本计划不建。

**Files:**
- Create: `zanzan/Core/Models/StoredLedger.swift`
- Create: `zanzan/Core/Models/SchemaV1.swift`
- Create: `zanzan/Core/Models/ZanzanMigrationPlan.swift`
- Create: `zanzan/App/AppModelContainer.swift`
- Test: `zanzanTests/SchemaV1Tests.swift`

**Interfaces:**
- Produces:
  - `final class StoredLedger: PersistentModel`，`init(name: String)`，字段见 Step 3。
  - `enum SchemaV1: VersionedSchema`（`versionIdentifier == Schema.Version(1, 0, 0)`，`models == [StoredLedger.self]`）。
  - `enum ZanzanMigrationPlan: SchemaMigrationPlan`（`schemas == [SchemaV1.self]`，`stages == []`）。
  - `enum AppModelContainer { static func make(inMemory: Bool = false) throws -> ModelContainer }`（Task 3 与全部后续测试消费）。

- [ ] **Step 1: 写失败测试**

`zanzanTests/SchemaV1Tests.swift`：

```swift
import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct SchemaV1Tests {
    @Test func 账本插入与读取往返() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let ledger = StoredLedger(name: "日常")
        context.insert(ledger)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<StoredLedger>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.name == "日常")
        #expect(fetched.first?.isDefault == false)
        #expect(fetched.first?.isSoftDeleted == false)
        #expect(fetched.first?.colorID == "blue")
    }

    @Test func 迁移计划以V1为唯一版本() {
        #expect(ZanzanMigrationPlan.schemas.count == 1)
        #expect(SchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `xcodebuild test -project zanzan.xcodeproj -scheme zanzan -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:zanzanTests -quiet`
Expected: **编译失败**，报 `cannot find 'AppModelContainer' / 'StoredLedger' in scope`。

- [ ] **Step 3: 实现模型**

`zanzan/Core/Models/StoredLedger.swift`（字段=通用四字段 + 文档 5.1；默认值一律写在声明处——轻量迁移与 CloudKit 双重要求；`uuid` 建非唯一索引）：

```swift
import Foundation
import SwiftData

/// 账本（数据库设计文档 5.1）
@Model
final class StoredLedger {
    #Index<StoredLedger>([\.uuid])

    var uuid: UUID = UUID()
    var name: String = ""
    var isDefault: Bool = false
    var iconKindRawValue: String = ""
    var iconPrimary: String = ""
    var iconSecondary: String = ""
    var iconIndex: Int = 0
    var colorID: String = "blue"
    var isArchived: Bool = false
    var sortOrder: Int = 0
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(name: String) {
        self.name = name
    }
}
```

- [ ] **Step 4: 实现版本登记簿与迁移计划**

`zanzan/Core/Models/SchemaV1.swift`：

```swift
import Foundation
import SwiftData

/// 版本登记簿 V1（数据库设计文档 13.1）
enum SchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [StoredLedger.self]
    }
}
```

`zanzan/Core/Models/ZanzanMigrationPlan.swift`：

```swift
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
```

- [ ] **Step 5: 实现容器工厂**

`zanzan/App/AppModelContainer.swift`（App 层装配；CloudKit 开关集中在此，开启同步时只改这一处 + entitlement）：

```swift
import Foundation
import SwiftData

/// ModelContainer 装配唯一入口（App 与测试共用）。
/// CloudKit 暂关（.none）；开启时改此处配置并添加 iCloud entitlement。
enum AppModelContainer {
    static func make(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: ZanzanMigrationPlan.self,
            configurations: configuration
        )
    }
}
```

- [ ] **Step 6: 运行测试确认通过**

Run: `xcodebuild test -project zanzan.xcodeproj -scheme zanzan -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:zanzanTests -quiet`
Expected: PASS（2 个测试全绿；模板文件 `zanzanTests.swift` 里的空测试同时通过，保留不动）。

- [ ] **Step 7: Commit**

```bash
git add -A
printf '%s\n' '✨ feat(core): 建立 SchemaV1 数据基座与容器工厂' '' '- add StoredLedger model per db design doc 5.1' '- register SchemaV1 and lightweight-only migration plan' '- add AppModelContainer factory with cloudkit disabled' '' 'Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>' > .git/COMMIT_EDITMSG
git commit -F .git/COMMIT_EDITMSG
```

---

### Task 3: RootView 导航壳 + 容器注入

**Files:**
- Create: `zanzan/App/RootView.swift`
- Create: `zanzan/Features/Transactions/TransactionsHomeView.swift`
- Create: `zanzan/Features/Stats/StatsHomeView.swift`
- Create: `zanzan/Features/Settings/SettingsHomeView.swift`
- Modify: `zanzan/App/ZanzanApp.swift`
- Delete: `zanzan/ContentView.swift`

**Interfaces:**
- Consumes: `AppModelContainer.make(inMemory:)`（Task 2）。
- Produces: `RootView`（TabView 壳，后续 Feature 页面替换各占位视图即可，不再动 App 层）。

- [ ] **Step 1: 三个占位首页**

`zanzan/Features/Transactions/TransactionsHomeView.swift`：

```swift
import SwiftUI

struct TransactionsHomeView: View {
    var body: some View {
        ContentUnavailableView(
            "还没有账单",
            systemImage: "list.bullet.rectangle",
            description: Text("记账功能开发中")
        )
        .navigationTitle("明细")
    }
}

#Preview {
    NavigationStack { TransactionsHomeView() }
}
```

`zanzan/Features/Stats/StatsHomeView.swift`：

```swift
import SwiftUI

struct StatsHomeView: View {
    var body: some View {
        ContentUnavailableView(
            "暂无统计",
            systemImage: "chart.pie",
            description: Text("统计功能开发中")
        )
        .navigationTitle("统计")
    }
}

#Preview {
    NavigationStack { StatsHomeView() }
}
```

`zanzan/Features/Settings/SettingsHomeView.swift`：

```swift
import SwiftUI

struct SettingsHomeView: View {
    var body: some View {
        ContentUnavailableView(
            "我的",
            systemImage: "person.crop.circle",
            description: Text("设置功能开发中")
        )
        .navigationTitle("我的")
    }
}

#Preview {
    NavigationStack { SettingsHomeView() }
}
```

- [ ] **Step 2: RootView（TabView + 每 Tab 独立 NavigationStack）**

`zanzan/App/RootView.swift`：

```swift
import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            Tab("明细", systemImage: "list.bullet.rectangle") {
                NavigationStack { TransactionsHomeView() }
            }
            Tab("统计", systemImage: "chart.pie") {
                NavigationStack { StatsHomeView() }
            }
            Tab("我的", systemImage: "person.crop.circle") {
                NavigationStack { SettingsHomeView() }
            }
        }
    }
}

#Preview {
    RootView()
}
```

- [ ] **Step 3: ZanzanApp 挂容器与 RootView，删除 ContentView**

`zanzan/App/ZanzanApp.swift` 全文改为：

```swift
import SwiftData
import SwiftUI

@main
struct ZanzanApp: App {
    private let container: ModelContainer

    init() {
        do {
            container = try AppModelContainer.make()
        } catch {
            // 本地库创建失败无降级路径：带上下文崩溃优于静默空转。
            fatalError("无法创建数据库容器：\(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}
```

```bash
git rm zanzan/ContentView.swift
```

- [ ] **Step 4: 全量验证（单元测试 + UI 启动测试）**

Run: `xcodebuild test -project zanzan.xcodeproj -scheme zanzan -destination 'platform=iOS Simulator,name=iPhone 17' -quiet`
Expected: PASS（zanzanTests 2 例 + zanzanUITests 模板启动测试全绿；UI 测试验证 App 冷启动不 crash，即容器装配成功）。

- [ ] **Step 5: Commit**

```bash
git add -A
printf '%s\n' '✨ feat(app): 搭建 RootView 导航壳并注入数据容器' '' '- add TabView shell with per-tab NavigationStack' '- add placeholder home views for transactions, stats, settings' '- wire AppModelContainer into app entry and drop template ContentView' '' 'Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>' > .git/COMMIT_EDITMSG
git commit -F .git/COMMIT_EDITMSG
```

---

## 完成定义

- `zanzan/` 下存在 `App/`、`Core/Models/`、`Features/{Transactions,Stats,Settings}/` 目录分层，依赖方向符合 spec（`Core/` 无 `import SwiftUI`）。
- `xcodebuild test`（全 target）绿：schema 往返、迁移计划登记、App 冷启动。
- 未建的目录（`Core/{Scopes,Projections,Drafts,Commands,ImportExport}`、`Features/{Ledgers,Accounts,Categories,Budgets}`、`Shared/`）**留待对应功能落地时随首个文件创建**——文件系统同步分组下空目录无意义，此为刻意不做而非遗漏。
