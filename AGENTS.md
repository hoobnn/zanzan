# 攒攒 · Agent 指南

始终使用简体中文沟通。

## 项目结构

- `zanzan/App/`：启动、根视图、SwiftData 容器
- `zanzan/Core/`：`Models`（SwiftData 持久化模型，类名即实体名，无前缀）、`Drafts`（校验草稿）、`Services`（写路径服务）、`Providers`（只读投影/查询）——所有写路径走 Draft → Service，不在视图里直接改模型
- `zanzan/Features/<Domain>/`：按账本/账户/流水/统计/设置拆分的 SwiftUI 页面
- `zanzan/Shared/`：跨功能工具；`zanzanTests/` 单元测试，`zanzanUITests/` UI 测试

## 文档（docs/）

| 文档 | 作用 |
| --- | --- |
| `docs/数据库设计文档.md` | **schema source of truth**（15 表/枚举/命名规范）；改 schema 必须回第 13 章走版本化流程 |
| `docs/功能路线图.md` | **功能排期 source of truth**（切片顺序、渐进披露原则），每合入一个切片更新 |
| `docs/superpowers/specs/` | 架构设计 spec |
| `docs/superpowers/plans/` | 各切片实施计划（brainstorm 产物） |

## 构建与测试

- `xcodebuild build -project zanzan.xcodeproj -scheme zanzan -destination 'generic/platform=iOS Simulator' -quiet`
- `xcodebuild test -project zanzan.xcodeproj -scheme zanzan -only-testing:zanzanTests -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled YES -parallel-testing-worker-count 2 -maximum-concurrent-test-simulator-destinations 2 -quiet`（去掉 `-only-testing` 含 UI 测试）
- 同一时间只运行一个 `xcodebuild test`，其内部最多并行 2 个测试实例；结束且确认没有 `xcodebuild` / `xctest` / `XCTRunner` 进程后，立即清空 `/Users/haobin/Library/Developer/XCTestDevices` 的子目录并复核为 0，禁止测试运行中清理
- 使用当前默认 Xcode 工具链，**不要设置 `DEVELOPER_DIR`**
- `pnpm install` 启用 husky + commitlint 提交校验

## 关键约定

- 金额一律用整数最小货币单位，禁止新增浮点金额路径
- SwiftData 上下文相关代码遵循现有 `@MainActor` 边界
- schema 已全量就位，功能开发只做 Draft/Service/Provider/UI 切片，不动 schema
- 单元测试用 Swift Testing（`@Test`/`#expect`）+ 内存容器，文件名 `<Subject>Tests.swift`；UI 测试用 XCTest；业务改动须覆盖成功路径、校验失败与软删除等边界

## 分支策略（GitHub Flow / 主干开发）

- main 永远可发布：切片小步合入 main，保持全量测试绿；不引入 Git Flow（无 develop/release/hotfix 长期分支）
- 大改动或需 review 的开短命 `feature/<topic>` 分支，合完即删
- 发版打 tag（如 `v1.0.0`），不开版本分支；旧版本 hotfix 需要时从 tag 开分支

## 提交

- 标题格式 `<emoji> <type>(<scope>): <subject>`，scope 小写，总长 ≤72 字符（映射见 `commitlint.config.js`），如 `✨ feat(accounts): 支持账户归档`
- 提交需加 AI 署名（`Co-Authored-By` + `🤖 Generated with Claude Code`）
- PR 说明动机与影响、已执行测试；UI 改动附截图，模型变更说明迁移与 CloudKit 影响
