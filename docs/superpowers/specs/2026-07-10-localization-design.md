# 硬编码文本抽离 + 中英双语 设计

日期：2026-07-10
状态：已确认

## 目标

抽离全部硬编码 UI 文案（约 183 处中文字面量，分布在 32 个文件），首要支持简体中文 + 英文双语。语言跟随系统，不做 App 内切换。

## 已确认决策

| 决策点 | 结论 |
| --- | --- |
| Key 策略 | 中文原文做 key，开发语言设为 zh-Hans，English 为翻译目标 |
| 种子数据 | 首次播种时用 `String(localized:)` 按系统语言写入数据库，之后不随语言切换 |
| 语言切换 | 跟随系统（iOS 自动提供设置→应用→首选语言入口），不做 App 内切换 |

## 架构：String Catalog

- 新增 `zanzan/Localizable.xcstrings`（String Catalog），语言 zh-Hans（源）+ en。
- 工程配置：
  - `developmentRegion` → `zh-Hans`
  - `knownRegions` 增加 `zh-Hans`、`en`
  - `SWIFT_EMIT_LOC_STRINGS = YES`（编译器自动提取 Swift 字符串进 Catalog）
- 构建一次后 Catalog 自动收录全部可提取中文条目，人工补全英文译文。

## 分层处理规则

1. **SwiftUI 视图层**（`Features/`、`App/`、`Shared/` 中接受 `LocalizedStringKey` 的 API：`Text`、`Label`、`Button`、`navigationTitle`、`TextField` placeholder 等）：编译器自动提取，代码不改。
2. **`String` 类型的展示文案**（变量、传参、拼接后再进视图的）：改为 `String(localized:)`。
3. **Core 层**：
   - `Commands/`、`Drafts/` 的 `errorDescription` 文案 → `String(localized:)`
   - `Projections/` 的展示文案（如 `MonthlyStatsProjector` 错误信息）→ `String(localized:)`
   - Models 层中文均为注释，无需处理。
4. **种子数据**（`DefaultDataSeeder`）：账本名、预置分类名等全部 `String(localized:)`，播种时按系统语言落库。
5. **不本地化清单**：
   - SF Symbol 名称、`accessibilityIdentifier`（UI 测试依赖）
   - `currencyCode` 等逻辑/数据字符串
   - `MoneyFormatter`：维持锁 CNY / zh_CN 不动（数据库设计文档 §4，测试确定性）

## 英文翻译

- 去重后在 xcstrings 内补全全部 en 译文。
- 中文无复数而英文需要复数的条目（如“共 N 笔”）使用 String Catalog 的 plural variation。

## 测试与验收

- 现有约 10 处直接 `#expect` 中文错误文案的断言 → 改为断言错误枚举 case，不依赖运行时语言。
- 验收标准：
  1. `xcodebuild build` 通过
  2. 全量单元测试绿
  3. 模拟器切换 en 抽查主要页面（记账/账本/资产/统计/设置）无残留中文 UI 文案

## 明确不做（YAGNI）

- App 内语言切换
- 已有用户数据（历史分类名等）的翻译迁移
- 繁体中文及其他语言
- 货币、日期格式本地化改造（维持现有锁定口径）
