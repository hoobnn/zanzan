# 攒攒（zanzan）

**简体中文** · [English](README.en.md)

一个 iOS 记账 App，用 SwiftUI + SwiftData 写，还在开发中，没有上架。

做它是因为我自己的账比较杂：好几张信用卡共用额度、经常垫付报销、有分期和外币。市面上的记账 App 要么记不了这么细，要么把所有入口都堆在首页。攒攒的想法是：记一笔要快，复杂功能等用到的时候再出现。

## 现在能用的

- 多账本、多账户，两级分类，支出 / 收入 / 转账，标签
- 月度预算和分类预算，可以把某笔流水排除在预算外
- 信用卡账单和多卡共享额度
- 报销和退款：垫付、分几次到账、合并打款都能对上
- 分期和贷款：等额本息、等额本金、先息后本等常见规则
- 周期记账（房租、工资这类）
- 多币种和跨币种转账
- 余额校准，理财估值也走这个入口
- CSV 导入导出（按内容去重，能整批撤销）、票据照片、完整备份与恢复
- 最近删除：误删的账本、账户、流水都能找回
- 界面中英文即时切换

还没做的：iCloud 同步（数据模型已按 CloudKit 设计，开启前还要做几项验证）、外部汇率接口。进度见 [功能路线图](docs/功能路线图.md)，数据结构见 [数据库设计文档](docs/数据库设计文档.md)。

## 技术栈

| 项 | 值 |
| --- | --- |
| 平台 | iOS 26+ |
| UI | SwiftUI，原生组件 + Liquid Glass |
| 存储 | SwiftData（15 张表），预留 CloudKit 私有库同步 |
| 语言 | Swift 6 |

## 本地运行

用 Xcode 打开 `zanzan.xcodeproj`，选 `zanzan` scheme 运行。

提交信息用 gitmoji 格式，由 husky + commitlint 检查：

```text
<emoji> <type>(<scope>): <subject>
```

emoji 和 type 一一对应（`✨ feat`、`🐛 fix`、`📝 docs`、`♻️ refactor` 等，完整列表在 `commitlint.config.js`），scope 小写，整行不超过 72 个字符。第一次克隆后先装钩子依赖：

```sh
pnpm install
```

## 许可证

[PolyForm Noncommercial 1.0.0](LICENSE)：个人和非商业用途可以自由使用、修改、分发；商业使用请先联系我。
