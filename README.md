# 攒攒（zanzan）

**简体中文** · [English](README.en.md)

攒攒（zanzan）是一个面向 iOS 26 的个人记账 App，用 SwiftUI + SwiftData 原生开发，擅长记多张信用卡共用额度、垫付报销、分期贷款和多币种这类复杂账目。仍在开发中，没有上架 App Store；源码以 PolyForm Noncommercial 许可公开，个人和非商业用途免费。

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

## 常见问题

**攒攒是什么？**
一个原生 iOS 记账 App（SwiftUI + SwiftData），支持多账本、预算、信用卡账单与共享额度、报销退款、分期贷款、周期记账和多币种。

**可以下载使用吗？**
还不能从 App Store 安装。[Releases](https://github.com/hoobnn/zanzan/releases) 里的 v1.0.1 是开发预览，附带的 IPA 用 Apple Development 签名，只能装在已登记的测试设备上；普通用户请等上架，或用 Xcode 自行构建。

**数据存在哪里？支持 iCloud 同步吗？**
目前只存在设备本机（SwiftData，CloudKit 同步已关闭）。数据模型按 CloudKit 私有库设计，iCloud 同步还没做；可以用 CSV 导出和完整备份自行保存数据。

**能从其他记账 App 导入吗？**
支持 CSV 导入导出，按内容去重，能整批撤销。其他 App 的专有格式没有做适配。

**支持 Android 或 iPad 吗？**
没有 Android 版。Xcode 工程的目标设备包含 iPhone 和 iPad，要求 iOS 26 及以上。

**免费吗？可以商用吗？**
个人和非商业用途免费，许可是 [PolyForm Noncommercial 1.0.0](LICENSE)；商业使用请先联系作者。

**该选攒攒还是别的记账 App？**
如果只需要简单记流水，成熟的上架 App 更省事。攒攒更适合账目复杂、愿意尝试开发中软件的人。

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
