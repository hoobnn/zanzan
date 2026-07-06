# 攒攒 主体工程架构设计

日期：2026-07-06 ｜ 状态：已确认 ｜ 上游基准：[`docs/数据库设计文档.md`](../../数据库设计文档.md)（第 9 节数据访问分层、第 13.2 节 CloudKit 红线）

## 0. 决策摘要

| 决策点 | 结论 |
| --- | --- |
| 工程组织 | 单 App target + 目录分层（不建 SPM 包，痛了再抽） |
| 视图层 | 原生 SwiftUI，无 ViewModel 层 |
| CloudKit | schema 第一天守 13.2 红线，同步开关先关（`.none`），功能稳定后开启 |
| 多平台 | iPad 同 target 自适应；macOS 后续加 Mac destination（非 Catalyst） |

## 1. 分层与目录

```
zanzan/
├── App/                  # zanzanApp、RootView、ModelContainer 装配
├── Core/                 # 纯逻辑层，不 import SwiftUI
│   ├── Models/           # 15 张 Stored* @Model、SchemaV1(VersionedSchema)、关键枚举
│   ├── Scopes/           # LedgerScope / ProjectionReadScope / ModelFiltering（谓词下推）
│   ├── Projections/      # *Projector + 页面展示模型（纯值类型）
│   ├── Drafts/           # *Draft（入口校验 + 归一化）
│   ├── Commands/         # *Commands（写路径、不变量、维护/重算命令）
│   └── ImportExport/     # TransactionCSVImporter / Exporter
├── Features/             # 按功能域分目录，每目录 = 页面 + 路由枚举
│   ├── Transactions/  Ledgers/  Accounts/  Categories/
│   ├── Budgets/  Stats/  Settings/
└── Shared/               # 通用 UI 组件、MoneyFormatter、扩展
```

- 依赖方向单向：`Features → Core → SwiftData`。
- **Core 不 import SwiftUI**（展示模型是值类型）。单 target 无编译器强制，靠代码评审约束。
- 命名与分层职责直接执行数据库文档第 9 节，不发明第二套词汇。

## 2. App 装配与数据流

- `zanzanApp` 建 `ModelContainer(SchemaV1, cloudKitDatabase: .none)`，经 `.modelContainer()` 注入。开 CloudKit 时改这一处配置 + 加 entitlement。
- **无 DI 框架**。Projector/Commands 是接收 `ModelContext` 的无状态 struct，View 就地构造。
- 读路径：简单列表用 `@Query`；聚合/跨表走 Projector（谓词下推，见文档第 4/8 节）。
- 写路径：表单绑定 `*Draft`（校验 + 归一化）→ 提交调 `*Commands`（维护不变量与 `updatedAt`）。
- **事务边界**：每条业务命令收尾显式 `modelContext.save()`，一条命令 = 一个事务（autosave 时机不可预测，不依赖）。
- **关系删除规则**：全库软删无硬删除，`deleteRule` 一律保持默认 `.nullify`、禁用 `.cascade`——级联软删由 Commands 显式执行，不交给存储层。
- Swift 6 严格并发：全 app 默认 MainActor 隔离（工程已设 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`）；重计算（统计、CSV 导入）需要时再下放 `@ModelActor`，不预建。**模型实例与 `ModelContext` 不跨 actor**：跨界只传 `uuid` 到目标 context 重取；Projector 输出纯值类型展示模型，正是为了可安全跨 actor / 跨层传递。

## 3. 导航与多平台

- `RootView` = `TabView` + 每 Tab 独立 `NavigationStack`。
- 每个 Feature 一个 `Hashable` 路由枚举，经 `navigationDestination` 解析。**目标页禁止在 init 中构造带谓词的 `@Query`**，谓词经 initializer 参数传入（历史教训）。
- iPad：同 target，`sidebarAdaptable` TabView + 需要分栏的页面用 `NavigationSplitView` 适配。
- macOS：给 target 加 Mac destination，平台分叉集中在 `RootView` 与少量 `#if os(macOS)`。

## 4. 错误处理与测试

三层防线（数据库文档第 9 节）：

1. Draft 校验错误 → 表单内联提示。
2. Commands `throws` 业务错误（`LocalizedError`）→ View `.alert`。
3. 投影器读到违例数据归一化自愈，绝不 crash、绝不静默算错。

测试约定：

- `zanzanTests` 统一 `@testable import zanzan`，Swift Testing + in-memory ModelContainer（跑真实现，不 mock 存储）。
- 基线三类：每条命令层不变量一测；缓存全量重算一致性（删光快照后逐分一致）；迁移测试（文档 13.5，发版门禁）。

## 5. 刻意不做

- 不建 SPM 包 / 多 target（macOS 立项或编译变慢时再抽，迁移时机写回本文档）。
- 无 DI 容器、无 ViewModel、无 Repository 协议抽象——Projector/Commands 就是访问层，SwiftData 不可替换也不必 mock。
- 暂无 CloudKit 开关 UI；同步开启是一次性配置变更。
