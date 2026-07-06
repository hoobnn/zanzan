# 攒攒 (zanzan)

一款基于 SwiftUI + SwiftData 的 iOS 记账应用（绿地项目，支持 CloudKit 同步）。

## 功能规划

以多账本记账为核心，覆盖：

- 多账本 / 多账户、两级分类、支出 / 收入 / 转账、标签
- 月度预算（含流水级豁免）、周期记账、CSV 导入（防重复）
- 报销（合并打款与多次到账）/ 退款
- 多币种（含跨币种转账）、信用卡（账单日 / 授信池）、消费分期 / 账单分期 / 贷款
- 余额校准 / 投资估值、归档停用、票据附件、记账位置、余额趋势、操作日志

> 数据库设计基准见 [`docs/数据库设计文档.md`](docs/数据库设计文档.md)（15 张表，`SchemaV1`）。

## 技术栈

| 项 | 值 |
| --- | --- |
| 平台 | iOS |
| UI | SwiftUI |
| 持久化 | SwiftData（底层 Core Data / SQLite），CloudKit 同步 |
| Swift | 6.0 |
| Bundle ID | `com.ikuyu.zanzan` |

## 开发

用 Xcode 打开 `zanzan.xcodeproj`，选中 `zanzan` scheme 运行。

### 提交规范

本仓库通过 husky + commitlint 强制 gitmoji 提交规范，提交信息 header 格式：

```
<emoji> <type>(<scope>): <subject>
```

emoji 与 type 强制 1:1（`✨ feat` / `🐛 fix` / `📝 docs` / `♻️ refactor` 等，全表见 `commitlint.config.js`），scope 小写，header ≤ 72 字符。

首次克隆后需安装钩子依赖：

```sh
pnpm install
```

## 许可证

[PolyForm Noncommercial License 1.0.0](LICENSE) —— 允许个人及任何非商业用途自由使用、修改、分发；商业使用需另行授权。
