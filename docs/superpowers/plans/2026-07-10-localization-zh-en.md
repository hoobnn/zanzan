# 中英双语本地化实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 抽离全部硬编码中文 UI 文案，以 String Catalog 支持 zh-Hans（源）+ en，语言跟随系统。

**Architecture:** 中文原文即本地化 key。SwiftUI `LocalizedStringKey` 上下文零改动、编译器自动提取；`String` 上下文（Core 层错误信息、枚举 displayName、三元表达式、String 参数）逐处改 `String(localized:)`；种子数据播种时按系统语言落库。最后用 `xcodebuild -exportLocalizations` 导出全部 key，生成含英文译文的 `Localizable.xcstrings`。

**Tech Stack:** Xcode String Catalog（.xcstrings）、`String(localized:)`、Swift Testing、XCTest（UI）。

**Spec:** `docs/superpowers/specs/2026-07-10-localization-design.md`

## Global Constraints

- 中文原文做 key，不引入语义化 key。
- 不本地化：SF Symbol 名、`accessibilityIdentifier`、`currencyCode`、`fatalError` 消息、`"¥ ****"` 掩码；`MoneyFormatter` 维持锁 CNY/zh_CN 不动。
- 不做：App 内语言切换、历史数据翻译迁移、繁体/第三语言、货币日期格式改造。
- 构建命令：`xcodebuild build -project zanzan.xcodeproj -scheme zanzan -destination 'generic/platform=iOS Simulator' -quiet`
- 单测命令：`xcodebuild test -project zanzan.xcodeproj -scheme zanzan -only-testing:zanzanTests -destination 'platform=iOS Simulator,name=iPhone 17' -quiet`
- 不设置 `DEVELOPER_DIR`。
- 提交格式 `<emoji> <type>(<scope>): <subject>`（commitlint 强制），带 AI 署名 trailer。

---

### Task 1: 工程配置 + 空 String Catalog + UI 测试锁定 zh-Hans

**Files:**
- Modify: `zanzan.xcodeproj/project.pbxproj`（developmentRegion / knownRegions）
- Create: `zanzan/Localizable.xcstrings`
- Modify: `zanzanUITests/zanzanUITests.swift:11-13`

**Interfaces:**
- Produces: 工程声明 zh-Hans（源语言）+ en 两种本地化；后续任务的 `String(localized:)` 都解析到该 Catalog。

- [ ] **Step 1: 改 pbxproj 语言配置**

`developmentRegion = en;` → `developmentRegion = "zh-Hans";`

```
knownRegions = (
    en,
    Base,
);
```
→
```
knownRegions = (
    en,
    "zh-Hans",
    Base,
);
```

确认 `SWIFT_EMIT_LOC_STRINGS = YES` 已存在（当前 pbxproj 已有 2 处，无需改）。

- [ ] **Step 2: 创建空 String Catalog**

新建 `zanzan/Localizable.xcstrings`（工程为 fileSystemSynchronized group，落盘即入 target）：

```json
{
  "sourceLanguage" : "zh-Hans",
  "strings" : {

  },
  "version" : "1.0"
}
```

- [ ] **Step 3: UI 测试锁定 zh-Hans 运行**

UI 测试用中文文案定位元素（14 处），锁定语言避免受模拟器系统语言影响。`zanzanUITests.swift` 中两个功能测试的 `XCUIApplication()` 创建后、`launch()` 前加：

```swift
app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
```

（`testLaunchPerformance` 不查文案，不用加。）

- [ ] **Step 4: 构建验证**

Run: 构建命令（见 Global Constraints）
Expected: Build Succeeded

- [ ] **Step 5: Commit**

```bash
git add zanzan.xcodeproj/project.pbxproj zanzan/Localizable.xcstrings zanzanUITests/zanzanUITests.swift
git commit -m "🔧 chore(i18n): 工程启用 zh-Hans/en 本地化与空 String Catalog"
```

---

### Task 2: Core 层文案改 String(localized:)

**Files:**
- Modify: `zanzan/Core/Drafts/AccountDraft.swift`、`CategoryDraft.swift`、`LedgerDraft.swift`、`TransactionDraft.swift`
- Modify: `zanzan/Core/Commands/AccountCommands.swift`、`CategoryCommands.swift`、`LedgerCommands.swift`、`TransactionCommands.swift`、`DefaultDataSeeder.swift`
- Modify: `zanzan/Core/Projections/MonthlyStatsProjector.swift`
- Modify: `zanzanTests/DefaultDataSeederTests.swift:30`

**Interfaces:**
- Consumes: Task 1 的本地化配置。
- Produces: Core 层全部用户可见文案走 Catalog；种子数据按运行时系统语言落库。

- [ ] **Step 1: 机械替换——错误信息与种子文案**

上述 10 个文件内，所有**用户可见**中文字符串字面量 `"X"` → `String(localized: "X")`。范围仅字符串字面量，注释不动。示例（TransactionDraft.swift:71-76）：

```swift
case .invalidAmount: String(localized: "金额须为大于 0 的数字（最多两位小数）")
case .missingAccount: String(localized: "请选择账户")
case .missingCategory: String(localized: "请选择分类")
case .missingTargetAccount: String(localized: "请选择转入账户")
case .sameTransferAccounts: String(localized: "转出与转入账户不能相同")
case .invalidFee: String(localized: "手续费格式不正确")
```

DefaultDataSeeder.swift 同样处理（账本名、账户名、全部 SeedCategory 名）：

```swift
try LedgerCommands(context: context).createLedger(LedgerDraft(name: String(localized: "日常账本")))
let cash = StoredAccount(name: String(localized: "现金"), kind: .fund)
SeedCategory(name: String(localized: "餐饮"), symbol: "fork.knife", children: [
    (String(localized: "早餐"), "sunrise"), ...
```

注意甄别：SF Symbol 名（`"fork.knife"` 等）、UserDefaults key、identifier 一律不包。

- [ ] **Step 2: 修种子测试的语言耦合断言**

`zanzanTests/DefaultDataSeederTests.swift:30` 按名称查找会随运行语言变化，改为同源解析（`String(localized:)` 默认走宿主 app bundle，与种子器一致）：

```swift
let dining = try #require(expenseRoots.first { $0.name == String(localized: "餐饮") })
```

- [ ] **Step 3: 残留扫描**

Run: `grep -rn '"[一-鿿][^"]*"' zanzan/Core --include="*.swift" | grep -v 'String(localized' | grep -v '^\s*//'`
Expected: 无用户可见文案残留（只允许注释内中文）。

- [ ] **Step 4: 全量单测**

Run: 单测命令
Expected: 全绿（当前 zh 模拟器下 key 即中文原文，行为不变）。

- [ ] **Step 5: Commit**

```bash
git add zanzan/Core zanzanTests/DefaultDataSeederTests.swift
git commit -m "🌐 feat(i18n): Core 层错误信息与种子数据走 String(localized:)"
```

---

### Task 3: 视图层非自动提取上下文改造

**Files:**
- Modify: `zanzan/Features/Settings/AppIcon/AppIconOption.swift`（displayName/description 6 处）
- Modify: `zanzan/Features/Settings/AppIcon/AppIconController.swift:30`
- Modify: `zanzan/Features/Settings/AppIcon/AppIconSettingsView.swift:24`（三元）
- Modify: `zanzan/Features/Transactions/TransactionKind+Display.swift`（3 处）
- Modify: `zanzan/Features/Accounts/AccountKind+Display.swift`（6 处）
- Modify: `zanzan/Features/Transactions/TransactionRowView.swift:28-32`（fallback 3 处）
- Modify: `zanzan/Features/Transactions/TransactionFormView.swift:100`（三元 navigationTitle）
- Modify: `zanzan/Features/Ledgers/LedgersListView.swift:48,53`、`zanzan/Features/Accounts/AccountsListView.swift:53,58,93`、`zanzan/Features/Assets/AssetsHomeView.swift:61,66,81,95-96,116-118,185,189-191`
- Modify: `zanzan/Features/Stats/StatsHomeView.swift`、`zanzan/Features/Transactions/TransactionsHomeView.swift`、`TransactionListView.swift`（仅当 Step 3 扫描确认漏提取时）

**Interfaces:**
- Consumes: Task 1 配置。
- Produces: 全部 `String` 上下文文案显式本地化；`LedgerFormView`/`AccountFormView` 的 `title: String` 参数签名不变，调用侧传已本地化字符串。

- [ ] **Step 1: 逐类改造**

规则：凡文案最终类型是 `String`（enum computed property、String 参数、三元表达式、字符串插值拼接）→ `String(localized:)`。`Text("字面量")` 等 `LocalizedStringKey` 上下文不动。

枚举 display（TransactionKind+Display / AccountKind+Display / AppIconOption 同款）：

```swift
case .expense: String(localized: "支出")
case .income: String(localized: "收入")
case .transfer: String(localized: "转账")
```

三元表达式（字面量三元会推导为 String 不走本地化，两支显式包裹；4 处）：

```swift
.navigationTitle(editingUUID == nil ? String(localized: "记一笔") : String(localized: "编辑流水"))
Button(account.isArchived ? String(localized: "取消归档") : String(localized: "归档"), ...)
Button(hidesAmounts ? String(localized: "显示金额") : String(localized: "隐藏金额"), ...)
.accessibilityValue(controller.selectedIcon == option ? String(localized: "已选择") : String(localized: "未选择"))
.accessibilityHint(collapsedKinds.contains(group.kind) ? String(localized: "展开分组") : String(localized: "折叠分组"))
```

String 参数与 fallback：

```swift
LedgerFormView(title: String(localized: "新建账本"), draft: LedgerDraft()) { ... }
transaction.category?.name ?? String(localized: "未分类")
```

AssetsHomeView 无障碍插值（189-191）：

```swift
var parts = [String(localized: "余额: \(money(group.balanceTotalMinorUnits))")]
parts.append(String(localized: "欠款: \(money(group.debtTotalMinorUnits))"))
```

AssetsHomeView `labeledAmount(_:)` / `loanCard(_:)` 若首参为 `String`，参数类型改 `LocalizedStringKey`（内部是 `Text` 展示）；调用点 `"总资产"` 等字面量不动。

不动：`ZanzanApp.swift:14` fatalError、`AssetsHomeView.swift:227` `"¥ ****"`。

- [ ] **Step 2: 构建 + 全量单测**

Run: 构建命令、单测命令
Expected: 全绿。

- [ ] **Step 3: 残留扫描**

Run: `grep -rn '"[一-鿿][^"]*"' zanzan/Features zanzan/App zanzan/Shared --include="*.swift" | grep -v 'String(localized'`
Expected: 剩余行均为 `LocalizedStringKey` 自动提取上下文（`Text`/`Label`/`Button("字面量"`/`navigationTitle("字面量"`/`Section`/`TextField`/`ContentUnavailableView`/`Tab(` 等）或明确豁免项。发现新的 String 上下文按 Step 1 规则补改。

- [ ] **Step 4: Commit**

```bash
git add zanzan/Features zanzan/App zanzan/Shared
git commit -m "🌐 feat(i18n): 视图层 String 上下文文案显式本地化"
```

---

### Task 4: 导出全部 key，生成含英文译文的 String Catalog

**Files:**
- Modify: `zanzan/Localizable.xcstrings`
- 临时产物放 scratchpad，不入库。

**Interfaces:**
- Consumes: Task 1-3 的全部可提取字符串。
- Produces: 完整 `Localizable.xcstrings`（key=中文原文，en 全量翻译）。

- [ ] **Step 1: 导出提取全部 key**

```bash
xcodebuild -exportLocalizations -project zanzan.xcodeproj \
  -localizationPath <scratchpad>/loc -exportLanguage zh-Hans -quiet
```

解析 `<scratchpad>/loc/zh-Hans.xcloc/Localized Contents/zh-Hans.xliff` 的全部 `<source>` 条目得到 key 清单（应 ≈180 条去重后）。

- [ ] **Step 2: 生成 xcstrings（含全部 en 译文）**

用脚本把 key 清单写回 `zanzan/Localizable.xcstrings`，每条：

```json
"记一笔" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Add Entry" } }
  }
}
```

翻译约定：导航标题/按钮/Tab 用 Title Case（如 记账→Records、账本→Ledgers、资产→Assets、统计→Stats、记一笔→Add Entry、支出→Expense、收入→Income、转账→Transfer）；错误/提示句用 sentence case（如 请选择账户→Please select an account）；种子分类名词单词首字母大写（餐饮→Dining、工资→Salary）。带格式符的 key（如 `余额: %@`）原样保留格式符。中文单数、英文需复数的计数条目用 plural variation：

```json
"共%lld笔" : {
  "localizations" : {
    "en" : { "variations" : { "plural" : {
      "one"   : { "stringUnit" : { "state" : "translated", "value" : "%lld entry" } },
      "other" : { "stringUnit" : { "state" : "translated", "value" : "%lld entries" } }
    } } }
  }
}
```

全部条目现场翻译，**不允许留空**。

- [ ] **Step 3: 完整性自检**

```bash
python3 -c "
import json; d = json.load(open('zanzan/Localizable.xcstrings'))
missing = [k for k,v in d['strings'].items()
           if 'en' not in (v.get('localizations') or {})]
assert not missing, missing; print('OK', len(d['strings']), 'keys')"
```

Expected: `OK <N> keys`，无 missing。

- [ ] **Step 4: 构建 + 全量单测**

Run: 构建命令、单测命令
Expected: 全绿。

- [ ] **Step 5: Commit**

```bash
git add zanzan/Localizable.xcstrings
git commit -m "🌐 feat(i18n): String Catalog 收录全量文案并补全英文翻译"
```

---

### Task 5: 端到端验证 + 文档收尾

**Files:**
- Modify: `docs/功能路线图.md`（标注本地化切片完成）

- [ ] **Step 1: 全量测试（含 UI 测试）**

Run: `xcodebuild test -project zanzan.xcodeproj -scheme zanzan -destination 'platform=iOS Simulator,name=iPhone 17' -quiet`
Expected: 单测 + UI 测试全绿（UI 测试已锁 zh-Hans）。

- [ ] **Step 2: en 环境抽查**

模拟器以 en 启动 app（`xcrun simctl launch` 前 `defaults` 或 launch args `-AppleLanguages (en)`），截图记账/账本/资产/统计/设置五页，确认无残留中文 UI 文案（用户既有数据除外）。受模拟器验证约束（真实 CloudKit 数据），以页面框架文案为准。

- [ ] **Step 3: 更新路线图并提交**

`docs/功能路线图.md` 标注「中英双语本地化」切片完成。

```bash
git add docs/功能路线图.md
git commit -m "📝 docs(product): 标注中英双语本地化切片完成"
```

---

## Self-Review 记录

- Spec 覆盖：架构/工程配置→Task 1；Core 与种子→Task 2；视图 String 上下文→Task 3；英文翻译+plural→Task 4；验收三条→Task 1/2/4 构建测试 + Task 5；不做清单→Global Constraints。无缺口。
- 测试语言耦合：单测中文断言均为测试自建数据回读，不受影响；唯一例外 DefaultDataSeederTests:30 已在 Task 2 处理；UI 测试锁 zh-Hans 在 Task 1 处理。
- 类型一致性：`LedgerFormView`/`AccountFormView` 维持 `title: String`，调用侧本地化，Task 3 内一致。
