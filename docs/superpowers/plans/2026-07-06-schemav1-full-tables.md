# SchemaV1 全量 15 表落地 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按 `docs/数据库设计文档.md`（source of truth）把全部 15 张表建入 SchemaV1，含关键枚举、关系、索引与流水自带派生逻辑，TDD 全绿。

**Architecture:** 单 module 分层：`zanzan/Core/Models/` 一模型一文件，全部注册进 `SchemaV1.models`；对象关系仅存在于流水簇（Transaction ↔ Account/Category/Tag），其余表间引用一律 `<实体>ID: UUID` 弱引用；本阶段只建 schema 层 + 模型自带派生，不建 Drafts/Commands/Projectors/Seeder（后续切片再做）。

**Tech Stack:** Swift 6.2 / SwiftData（CloudKit 兼容口径但 `cloudKitDatabase: .none`）/ Swift Testing（`@Test` + `#expect`）。

## Global Constraints

- **SwiftData 铁律**（设计文档 §4，逐条强制）：列默认值写在属性声明处（轻量迁移不走 `init`）；关系全可空、全部显式声明 inverse（`@Relationship` 宏只放关系一侧）；全字段有声明处默认值；禁 `#Unique`；结构化小字段用 Codable 值类型（`[Int]`/`[String]`/`[UUID]`），禁 JSON 字符串列。
- **命名规范**（§2）：业务主键 `uuid`（禁 `id`）；外键 `<实体>ID: UUID`；枚举列 `<字段>RawValue: String` + 同名计算属性；金额 `<字段>MinorUnits: Int`；利率 `<字段>Bps: Int`；时间 `<事件>At: Date`；备注 `note: String` 非可空空串。
- **枚举 rawValue 一律英文小驼峰**（§6），落库串终生不改；语义类枚举解析失败返回 `nil`（按「未知」处理，严禁回写兜底值）。
- **索引**（§8）：被反查实体的 `uuid` 建非唯一 `#Index`（Transaction / Account / Category / Ledger / Tag / CreditPool / InstallmentPlan）；复合索引按第 8 节表格，等值列在前、排序列在后。
- 通用基础字段四件套每表必带：`uuid` / `isSoftDeleted` / `createdAt` / `updatedAt`，模式照抄 `StoredLedger.swift`。
- 测试命令：`xcodebuild test -project zanzan.xcodeproj -scheme zanzan -only-testing:zanzanTests -destination 'platform=iOS Simulator,name=iPhone 17' -quiet`。**不要设置 `DEVELOPER_DIR`**（工程 objectVersion=110，默认工具链已是 Xcode-beta）。
- Xcode 工程为文件系统同步分组：新建 `.swift` 文件放对目录即自动入 target，无需改 pbxproj。
- 提交格式（commitlint 强制 gitmoji）：`<emoji> <type>(<scope>): <subject>`，subject 中文、header ≤72 字符，正文后加 `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`。
- 测试统一 `@testable import zanzan`，容器统一 `AppModelContainer.make(inMemory: true)`。

---

### Task 1: 关键枚举与图标描述符

**Files:**
- Create: `zanzan/Core/Models/ModelEnums.swift`
- Create: `zanzan/Core/Models/StoredIconDescriptor.swift`
- Test: `zanzanTests/ModelEnumsTests.swift`

**Interfaces:**
- Consumes: 无（纯 Swift 值类型）。
- Produces: 10 个 `String, Codable, CaseIterable, Sendable` 枚举——`TransactionKind`（expense/income/transfer）、`AccountKind`（fund/credit/prepaid/investment/receivable/payable）、`TransactionSourceKind`（manual/csvImport/recurring/voice/installment/adjustment）、`TransactionLinkKind`（reimbursement/refund）、`ReimbursementStatus`（waiting/settled）、`RecurrenceFrequency`（daily/weekly/monthly）、`InstallmentPlanKind`（purchase/statement/loan）、`AmortizationKind`（annuity/linearPrincipal/interestOnly/flatFee/custom）、`InstallmentPlanStatus`（active/completed/settledEarly）、`InstallmentPeriodStatus`（pending/settled/cancelled）；以及 `StoredIconDescriptor`（含 `Kind`: symbol/asset/emoji）。后续所有模型的 `<字段>RawValue` 列均以这些枚举的 rawValue 落库。

- [ ] **Step 1: 写失败测试**

```swift
// zanzanTests/ModelEnumsTests.swift
import Testing
@testable import zanzan

struct ModelEnumsTests {
    @Test func 多词rawValue与文档锁定一致() {
        // 单词 case 的 rawValue 不会漂移，只锁多词拼写（落库串终生不改）
        #expect(TransactionSourceKind.csvImport.rawValue == "csvImport")
        #expect(AmortizationKind.linearPrincipal.rawValue == "linearPrincipal")
        #expect(AmortizationKind.interestOnly.rawValue == "interestOnly")
        #expect(AmortizationKind.flatFee.rawValue == "flatFee")
        #expect(InstallmentPlanStatus.settledEarly.rawValue == "settledEarly")
    }

    @Test func 枚举取值数量与文档一致() {
        #expect(TransactionKind.allCases.count == 3)
        #expect(AccountKind.allCases.count == 6)
        #expect(TransactionSourceKind.allCases.count == 6)
        #expect(TransactionLinkKind.allCases.count == 2)
        #expect(ReimbursementStatus.allCases.count == 2)
        #expect(RecurrenceFrequency.allCases.count == 3)
        #expect(InstallmentPlanKind.allCases.count == 3)
        #expect(AmortizationKind.allCases.count == 5)
        #expect(InstallmentPlanStatus.allCases.count == 3)
        #expect(InstallmentPeriodStatus.allCases.count == 3)
    }

    @Test func 图标描述符Kind三种能力() {
        #expect(StoredIconDescriptor.Kind(rawValue: "symbol") == .symbol)
        #expect(StoredIconDescriptor.Kind(rawValue: "asset") == .asset)
        #expect(StoredIconDescriptor.Kind(rawValue: "emoji") == .emoji)
        #expect(StoredIconDescriptor.Kind(rawValue: "sticker") == nil)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `xcodebuild test -project zanzan.xcodeproj -scheme zanzan -only-testing:zanzanTests -destination 'platform=iOS Simulator,name=iPhone 17' -quiet`
Expected: 编译失败——`cannot find 'TransactionSourceKind' in scope` 等。

- [ ] **Step 3: 实现枚举与图标描述符**

```swift
// zanzan/Core/Models/ModelEnums.swift
import Foundation

/// 关键枚举（数据库设计文档 §6）。rawValue 一律英文小驼峰，落库串终生不改；
/// 只加值不改值。语义类枚举解析失败一律返回 nil（按「未知」处理，禁回写兜底）。

enum TransactionKind: String, Codable, CaseIterable, Sendable {
    case expense, income, transfer
}

enum AccountKind: String, Codable, CaseIterable, Sendable {
    case fund, credit, prepaid, investment, receivable, payable
}

enum TransactionSourceKind: String, Codable, CaseIterable, Sendable {
    case manual, csvImport, recurring, voice, installment, adjustment
}

enum TransactionLinkKind: String, Codable, CaseIterable, Sendable {
    case reimbursement, refund
}

enum ReimbursementStatus: String, Codable, CaseIterable, Sendable {
    case waiting, settled
}

enum RecurrenceFrequency: String, Codable, CaseIterable, Sendable {
    case daily, weekly, monthly
}

enum InstallmentPlanKind: String, Codable, CaseIterable, Sendable {
    case purchase, statement, loan
}

enum AmortizationKind: String, Codable, CaseIterable, Sendable {
    case annuity, linearPrincipal, interestOnly, flatFee, custom
}

enum InstallmentPlanStatus: String, Codable, CaseIterable, Sendable {
    case active, completed, settledEarly
}

enum InstallmentPeriodStatus: String, Codable, CaseIterable, Sendable {
    case pending, settled, cancelled
}
```

```swift
// zanzan/Core/Models/StoredIconDescriptor.swift
import Foundation

/// 图标四件套的值类型描述符（数据库设计文档 §2/§6）。
/// 各表以摊平的四列落库（iconKindRawValue/iconPrimary/iconSecondary/iconIndex），
/// 本类型供展示层组装；Kind 按能力而非素材目录定义。
struct StoredIconDescriptor: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case symbol // SF Symbol：primary = systemName
        case asset  // 内置素材：primary = 素材组、secondary = 素材名、index 备用序号
        case emoji  // primary = emoji 字符
    }

    var kind: Kind
    var primary: String = ""
    var secondary: String = ""
    var index: Int = 0
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: 同 Step 2 命令
Expected: PASS（新增 3 例 + 既有 SchemaV1Tests 全绿）。

- [ ] **Step 5: Commit**

```bash
git add zanzan/Core/Models/ModelEnums.swift zanzan/Core/Models/StoredIconDescriptor.swift zanzanTests/ModelEnumsTests.swift
git commit -m "$(printf '%s\n' '✨ feat(core): 添加 schema 关键枚举与图标描述符' '' '- ten semantic enums with camelCase raw values locked by tests' '- StoredIconDescriptor value type for flattened icon columns' '' 'Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 2: 流水关系簇——StoredAccount / StoredCategory / StoredTag / StoredTransaction

四模型互相引用（对象关系 + 显式 inverse），必须同任务落地才可编译。本任务只建 schema 与枚举访问器，派生逻辑在 Task 3。

**Files:**
- Create: `zanzan/Core/Models/StoredAccount.swift`
- Create: `zanzan/Core/Models/StoredCategory.swift`
- Create: `zanzan/Core/Models/StoredTag.swift`
- Create: `zanzan/Core/Models/StoredTransaction.swift`
- Modify: `zanzan/Core/Models/SchemaV1.swift:9`（models 数组）
- Test: `zanzanTests/TransactionClusterSchemaTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `TransactionKind` / `AccountKind` / `TransactionSourceKind` / `ReimbursementStatus` / `TransactionLinkKind`。
- Produces:
  - `StoredAccount(name: String, kind: AccountKind)`，含 `kind: AccountKind?`、`transactions: [StoredTransaction]?`（inverse of `account`）、`incomingTransfers: [StoredTransaction]?`（inverse of `targetAccount`）。
  - `StoredCategory(name: String, kind: TransactionKind, sortOrder: Int)`，含 `kind: TransactionKind?`、`transactions: [StoredTransaction]?`。
  - `StoredTag(name: String)`，含 `transactions: [StoredTransaction]?`（多对多 inverse of `tags`）。
  - `StoredTransaction(kind: TransactionKind, amountMinorUnits: Int, occurredAt: Date, ledgerID: UUID)`，含 `account` / `targetAccount` / `category` / `tags` 关系与 `kind` / `sourceKind` / `reimbursementStatus` / `settlementKind` 计算属性。

- [ ] **Step 1: 写失败测试**

```swift
// zanzanTests/TransactionClusterSchemaTests.swift
import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct TransactionClusterSchemaTests {
    @Test func 支出流水与账户分类标签关系往返() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let ledger = StoredLedger(name: "日常")
        let account = StoredAccount(name: "招行储蓄卡", kind: .fund)
        let category = StoredCategory(name: "餐饮", kind: .expense, sortOrder: 0)
        let tag = StoredTag(name: "出差")
        context.insert(ledger)
        context.insert(account)
        context.insert(category)
        context.insert(tag)

        let txn = StoredTransaction(
            kind: .expense, amountMinorUnits: 2500,
            occurredAt: .now, ledgerID: ledger.uuid
        )
        txn.account = account
        txn.category = category
        txn.tags = [tag]
        context.insert(txn)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<StoredTransaction>()).first)
        #expect(fetched.kind == .expense)
        #expect(fetched.account?.name == "招行储蓄卡")
        #expect(fetched.category?.name == "餐饮")
        #expect(fetched.tags?.count == 1)
        #expect(fetched.currencyCode == "CNY")
        #expect(fetched.sourceKind == .manual)
        #expect(fetched.attachmentFileNames.isEmpty)

        // 显式 inverse：反向可达
        #expect(account.transactions?.count == 1)
        #expect(category.transactions?.count == 1)
        #expect(tag.transactions?.count == 1)
    }

    @Test func 转账流水双账户与到账金额往返() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let source = StoredAccount(name: "招行卡", kind: .fund)
        let target = StoredAccount(name: "美元账户", kind: .fund)
        context.insert(source)
        context.insert(target)

        let txn = StoredTransaction(
            kind: .transfer, amountMinorUnits: 72000,
            occurredAt: .now, ledgerID: UUID()
        )
        txn.account = source
        txn.targetAccount = target
        txn.targetAmountMinorUnits = 10000
        txn.fxRateToBase = Decimal(string: "7.2")
        context.insert(txn)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<StoredTransaction>()).first)
        #expect(fetched.targetAccount?.name == "美元账户")
        #expect(fetched.targetAmountMinorUnits == 10000)
        #expect(fetched.fxRateToBase == Decimal(string: "7.2"))
        #expect(target.incomingTransfers?.count == 1)
        #expect(target.transactions?.isEmpty != false)
    }

    @Test func 语义类枚举未知值解析为nil且原串保留() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let txn = StoredTransaction(
            kind: .expense, amountMinorUnits: 100,
            occurredAt: .now, ledgerID: UUID()
        )
        txn.kindRawValue = "cryptoStaking" // 未来版本写入的未知值
        context.insert(txn)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<StoredTransaction>()).first)
        #expect(fetched.kind == nil)
        #expect(fetched.kindRawValue == "cryptoStaking")
        #expect(fetched.reimbursementStatus == nil) // 空串 = 非报销
        #expect(fetched.settlementKind == nil)      // 空串 = 非到账单
    }

    @Test func 账户信用字段与开关默认值() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let card = StoredAccount(name: "招行信用卡", kind: .credit)
        card.creditLimitMinorUnits = 5_000_000
        card.statementDay = 5
        card.paymentDueDay = 23
        context.insert(card)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<StoredAccount>()).first)
        #expect(fetched.kind == .credit)
        #expect(fetched.creditLimitMinorUnits == 5_000_000)
        #expect(fetched.creditPoolID == nil)
        #expect(fetched.isIncludedInNetWorth)
        #expect(fetched.isSelectableForRecord)
        #expect(!fetched.isArchived)
        #expect(fetched.initialBalanceMinorUnits == 0)
    }

    @Test func 分类两级树与归属字段往返() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let parent = StoredCategory(name: "餐饮", kind: .expense, sortOrder: 0)
        let child = StoredCategory(name: "早餐", kind: .expense, sortOrder: 0)
        child.parentID = parent.uuid
        context.insert(parent)
        context.insert(child)
        try context.save()

        let all = try context.fetch(FetchDescriptor<StoredCategory>())
        let fetchedChild = try #require(all.first { $0.name == "早餐" })
        #expect(fetchedChild.parentID == parent.uuid)
        #expect(fetchedChild.ledgerID == nil) // nil = 全局分类
        #expect(!fetchedChild.isBuiltIn)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `xcodebuild test -project zanzan.xcodeproj -scheme zanzan -only-testing:zanzanTests -destination 'platform=iOS Simulator,name=iPhone 17' -quiet`
Expected: 编译失败——`cannot find 'StoredAccount' in scope` 等。

- [ ] **Step 3: 实现四模型并注册**

```swift
// zanzan/Core/Models/StoredAccount.swift
import Foundation
import SwiftData

/// 资产/账户（数据库设计文档 5.2）。当前余额 = 期初 + 流水派生，不落库。
@Model
final class StoredAccount {
    #Index<StoredAccount>([\.uuid])

    var uuid: UUID = UUID()
    var name: String = ""
    var subtitle: String = ""
    var kindRawValue: String = ""
    var iconKindRawValue: String = ""
    var iconPrimary: String = ""
    var iconSecondary: String = ""
    var iconIndex: Int = 0
    var currencyCode: String = "CNY"
    var initialBalanceMinorUnits: Int = 0
    var creditLimitMinorUnits: Int? = nil
    var creditPoolID: UUID? = nil
    var statementDay: Int? = nil
    var paymentDueDay: Int? = nil
    var note: String = ""
    var isIncludedInNetWorth: Bool = true
    var isSelectableForRecord: Bool = true
    var isArchived: Bool = false
    var sortOrder: Int = 0
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    /// 收支流水 + 转账转出方（inverse of StoredTransaction.account）
    @Relationship(deleteRule: .nullify, inverse: \StoredTransaction.account)
    var transactions: [StoredTransaction]? = nil

    /// 转账转入方反查（inverse of StoredTransaction.targetAccount）
    @Relationship(deleteRule: .nullify, inverse: \StoredTransaction.targetAccount)
    var incomingTransfers: [StoredTransaction]? = nil

    /// 语义类枚举：未知值返回 nil，禁回写兜底（设计文档 §4 前向兼容）
    var kind: AccountKind? { AccountKind(rawValue: kindRawValue) }

    init(name: String, kind: AccountKind) {
        self.name = name
        self.kindRawValue = kind.rawValue
    }
}
```

```swift
// zanzan/Core/Models/StoredCategory.swift
import Foundation
import SwiftData

/// 收支分类，自引用两级树经 parentID 弱引用表达（数据库设计文档 5.3）
@Model
final class StoredCategory {
    #Index<StoredCategory>([\.uuid])

    var uuid: UUID = UUID()
    var name: String = ""
    var kindRawValue: String = ""
    var iconKindRawValue: String = ""
    var iconPrimary: String = ""
    var iconSecondary: String = ""
    var iconIndex: Int = 0
    var sortOrder: Int = 0
    var parentID: UUID? = nil
    var ledgerID: UUID? = nil
    var isBuiltIn: Bool = false
    var isArchived: Bool = false
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    @Relationship(deleteRule: .nullify, inverse: \StoredTransaction.category)
    var transactions: [StoredTransaction]? = nil

    /// 方向仅 expense/income 合法（命令层校验），transfer 不挂分类
    var kind: TransactionKind? { TransactionKind(rawValue: kindRawValue) }

    init(name: String, kind: TransactionKind, sortOrder: Int) {
        self.name = name
        self.kindRawValue = kind.rawValue
        self.sortOrder = sortOrder
    }
}
```

```swift
// zanzan/Core/Models/StoredTag.swift
import Foundation
import SwiftData

/// 标签，与流水原生多对多（数据库设计文档 5.6）
@Model
final class StoredTag {
    #Index<StoredTag>([\.uuid])

    var uuid: UUID = UUID()
    var name: String = ""
    var colorID: String = "blue"
    var sortOrder: Int = 0
    var ledgerID: UUID? = nil
    var isArchived: Bool = false
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    @Relationship(deleteRule: .nullify, inverse: \StoredTransaction.tags)
    var transactions: [StoredTransaction]? = nil

    init(name: String) {
        self.name = name
    }
}
```

```swift
// zanzan/Core/Models/StoredTransaction.swift
import Foundation
import SwiftData

/// 流水主表（数据库设计文档 5.4）。kind 终生不可改写；
/// 复合索引匹配主查询 WHERE isSoftDeleted = 0 AND ledgerID = ? ORDER BY occurredAt DESC。
@Model
final class StoredTransaction {
    #Index<StoredTransaction>([\.uuid], [\.isSoftDeleted, \.ledgerID, \.occurredAt])

    var uuid: UUID = UUID()
    // 核心
    var kindRawValue: String = ""
    var amountMinorUnits: Int = 0
    var occurredAt: Date = Date.now
    var note: String = ""
    var ledgerID: UUID? = nil // 语义必填；CloudKit 兼容声明可空，命令层保证非空
    var account: StoredAccount? = nil
    var targetAccount: StoredAccount? = nil
    var category: StoredCategory? = nil
    var tags: [StoredTag]? = nil
    var attachmentFileNames: [String] = []
    var locationName: String = ""
    var locationLatitude: Double? = nil
    var locationLongitude: Double? = nil
    // 统计口径开关
    var isExcludedFromBudget: Bool = false
    var isExcludedFromStats: Bool = false
    // 多币种
    var currencyCode: String = "CNY"
    var targetAmountMinorUnits: Int? = nil
    var fxRateToBase: Decimal? = nil
    var feeMinorUnits: Int = 0
    // 来源包
    var sourceKindRawValue: String = "manual"
    var sourceID: UUID? = nil
    // 报销/退款
    var reimbursementStatusRawValue: String = ""
    var settlementKindRawValue: String = ""
    // 通用
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    /// 语义类枚举：未知值返回 nil，原串保留、禁回写兜底（设计文档 §4 前向兼容）
    var kind: TransactionKind? { TransactionKind(rawValue: kindRawValue) }
    var sourceKind: TransactionSourceKind? { TransactionSourceKind(rawValue: sourceKindRawValue) }
    /// 空串 = 非报销单，与未知值同为 nil；区分逻辑属命令/投影层
    var reimbursementStatus: ReimbursementStatus? { ReimbursementStatus(rawValue: reimbursementStatusRawValue) }
    /// 空串 = 非到账单
    var settlementKind: TransactionLinkKind? { TransactionLinkKind(rawValue: settlementKindRawValue) }

    init(kind: TransactionKind, amountMinorUnits: Int, occurredAt: Date, ledgerID: UUID) {
        self.kindRawValue = kind.rawValue
        self.amountMinorUnits = amountMinorUnits
        self.occurredAt = occurredAt
        self.ledgerID = ledgerID
    }
}
```

`zanzan/Core/Models/SchemaV1.swift` 的 models 数组改为：

```swift
    static var models: [any PersistentModel.Type] {
        [
            StoredLedger.self,
            StoredAccount.self,
            StoredCategory.self,
            StoredTransaction.self,
            StoredTag.self,
        ]
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: 同 Step 2 命令
Expected: PASS（新增 5 例 + 既有全绿）。

- [ ] **Step 5: Commit**

```bash
git add zanzan/Core/Models/StoredAccount.swift zanzan/Core/Models/StoredCategory.swift zanzan/Core/Models/StoredTag.swift zanzan/Core/Models/StoredTransaction.swift zanzan/Core/Models/SchemaV1.swift zanzanTests/TransactionClusterSchemaTests.swift
git commit -m "$(printf '%s\n' '✨ feat(core): 建入账户/分类/标签/流水关系簇' '' '- four models with explicit inverse relationships and uuid indexes' '- compound index on (isSoftDeleted, ledgerID, occurredAt)' '- semantic enum accessors return nil for unknown raw values' '' 'Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 3: StoredTransaction 自带派生逻辑

设计文档 5.4「模型自带派生（勿在页面重算）」：`signedMinorUnits` 与 `balanceDeltaMinorUnits(for:)`。

**Files:**
- Modify: `zanzan/Core/Models/StoredTransaction.swift`（类尾追加派生成员）
- Test: `zanzanTests/TransactionDerivationTests.swift`

**Interfaces:**
- Consumes: Task 2 的 `StoredTransaction` / `StoredAccount`。
- Produces: `var signedMinorUnits: Int`（支出负/收入正/转账与未知 0）；`func balanceDeltaMinorUnits(for accountUUID: UUID) -> Int`（含 fee 口径：转出方 −(amount+fee)，转入方 +(targetAmount ?? amount)）。

- [ ] **Step 1: 写失败测试**

```swift
// zanzanTests/TransactionDerivationTests.swift
import Foundation
import Testing
@testable import zanzan

@MainActor
struct TransactionDerivationTests {
    private func makeTransaction(kind: TransactionKind, amount: Int) -> StoredTransaction {
        StoredTransaction(kind: kind, amountMinorUnits: amount, occurredAt: .now, ledgerID: UUID())
    }

    @Test func 符号金额支出负收入正转账零() {
        #expect(makeTransaction(kind: .expense, amount: 2500).signedMinorUnits == -2500)
        #expect(makeTransaction(kind: .income, amount: 8800).signedMinorUnits == 8800)
        #expect(makeTransaction(kind: .transfer, amount: 100).signedMinorUnits == 0)
    }

    @Test func 未知类型符号金额为零() {
        let txn = makeTransaction(kind: .expense, amount: 100)
        txn.kindRawValue = "cryptoStaking"
        #expect(txn.signedMinorUnits == 0)
    }

    @Test func 支出余额口径含手续费() {
        let account = StoredAccount(name: "卡", kind: .fund)
        let txn = makeTransaction(kind: .expense, amount: 2500)
        txn.account = account
        txn.feeMinorUnits = 100
        #expect(txn.balanceDeltaMinorUnits(for: account.uuid) == -2600)
        #expect(txn.balanceDeltaMinorUnits(for: UUID()) == 0) // 无关账户
    }

    @Test func 转账余额口径转出含费转入按到账金额() {
        let source = StoredAccount(name: "招行", kind: .fund)
        let target = StoredAccount(name: "美元户", kind: .fund)
        let txn = makeTransaction(kind: .transfer, amount: 72000)
        txn.account = source
        txn.targetAccount = target
        txn.feeMinorUnits = 500
        txn.targetAmountMinorUnits = 10000 // 跨币种到账金额
        #expect(txn.balanceDeltaMinorUnits(for: source.uuid) == -72500)
        #expect(txn.balanceDeltaMinorUnits(for: target.uuid) == 10000)
    }

    @Test func 同币种转账转入按转出金额() {
        let source = StoredAccount(name: "招行", kind: .fund)
        let target = StoredAccount(name: "现金", kind: .fund)
        let txn = makeTransaction(kind: .transfer, amount: 30000)
        txn.account = source
        txn.targetAccount = target
        #expect(txn.balanceDeltaMinorUnits(for: target.uuid) == 30000)
    }

    @Test func 未知类型不影响余额() {
        let account = StoredAccount(name: "卡", kind: .fund)
        let txn = makeTransaction(kind: .expense, amount: 100)
        txn.account = account
        txn.kindRawValue = "cryptoStaking"
        #expect(txn.balanceDeltaMinorUnits(for: account.uuid) == 0)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `xcodebuild test -project zanzan.xcodeproj -scheme zanzan -only-testing:zanzanTests -destination 'platform=iOS Simulator,name=iPhone 17' -quiet`
Expected: 编译失败——`value of type 'StoredTransaction' has no member 'signedMinorUnits'`。

- [ ] **Step 3: 在 StoredTransaction 类尾（init 之前）追加派生成员**

```swift
    /// 收支符号金额：支出负、收入正、转账 0；语义未知按 0（读路径负责剔除与提示）
    var signedMinorUnits: Int {
        switch kind {
        case .expense: -amountMinorUnits
        case .income: amountMinorUnits
        case .transfer, nil: 0
        }
    }

    /// 对指定账户的余额影响（分）。fee 恒为流出：
    /// 转出方 delta = −(amount + fee)，转入方 = +(targetAmount ?? amount)（设计文档 5.4）。
    /// 语义未知的流水不影响余额（读路径按「未知」处理）。
    func balanceDeltaMinorUnits(for accountUUID: UUID) -> Int {
        guard let kind else { return 0 }
        let isSource = account?.uuid == accountUUID
        let isTarget = targetAccount?.uuid == accountUUID
        switch kind {
        case .expense:
            return isSource ? -(amountMinorUnits + feeMinorUnits) : 0
        case .income:
            return isSource ? amountMinorUnits - feeMinorUnits : 0
        case .transfer:
            var delta = 0
            if isSource { delta -= amountMinorUnits + feeMinorUnits }
            if isTarget { delta += targetAmountMinorUnits ?? amountMinorUnits }
            return delta
        }
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: 同 Step 2 命令
Expected: PASS（新增 6 例）。

- [ ] **Step 5: Commit**

```bash
git add zanzan/Core/Models/StoredTransaction.swift zanzanTests/TransactionDerivationTests.swift
git commit -m "$(printf '%s\n' '✨ feat(core): 流水自带符号金额与余额派生逻辑' '' '- signedMinorUnits: expense negative, income positive, transfer zero' '- balanceDeltaMinorUnits honors fee outflow and cross-currency target amount' '- unknown kind contributes zero, left to read-path handling' '' 'Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 4: 核心域收尾——StoredTransactionLink / StoredBudget / StoredCreditPool

三表均为 UUID 弱引用、无对象关系，可独立落地。

**Files:**
- Create: `zanzan/Core/Models/StoredTransactionLink.swift`
- Create: `zanzan/Core/Models/StoredBudget.swift`
- Create: `zanzan/Core/Models/StoredCreditPool.swift`
- Modify: `zanzan/Core/Models/SchemaV1.swift`（models 数组追加三项）
- Test: `zanzanTests/CoreDomainSchemaTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `TransactionLinkKind`。
- Produces:
  - `StoredTransactionLink(originalTransactionID: UUID, settlementTransactionID: UUID, kind: TransactionLinkKind, amountMinorUnits: Int)`，含 `kind: TransactionLinkKind?`。
  - `StoredBudget(ledgerID: UUID, amountMinorUnits: Int)`（`categoryID`/`periodYear`/`periodMonth` 默认 nil = 总预算模板行）。
  - `StoredCreditPool(name: String, totalLimitMinorUnits: Int)`。

- [ ] **Step 1: 写失败测试**

```swift
// zanzanTests/CoreDomainSchemaTests.swift
import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct CoreDomainSchemaTests {
    @Test func 流水关联行往返() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let originalID = UUID()
        let settlementID = UUID()
        let link = StoredTransactionLink(
            originalTransactionID: originalID,
            settlementTransactionID: settlementID,
            kind: .reimbursement,
            amountMinorUnits: 60000
        )
        context.insert(link)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<StoredTransactionLink>()).first)
        #expect(fetched.originalTransactionID == originalID)
        #expect(fetched.settlementTransactionID == settlementID)
        #expect(fetched.kind == .reimbursement)
        #expect(fetched.amountMinorUnits == 60000)
    }

    @Test func 预算模板行与按月实体行语义() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let ledgerID = UUID()
        let template = StoredBudget(ledgerID: ledgerID, amountMinorUnits: 300_000)
        let monthly = StoredBudget(ledgerID: ledgerID, amountMinorUnits: 500_000)
        monthly.periodYear = 2026
        monthly.periodMonth = 7
        context.insert(template)
        context.insert(monthly)
        try context.save()

        let all = try context.fetch(FetchDescriptor<StoredBudget>())
        #expect(all.count == 2)
        let fetchedTemplate = try #require(all.first { $0.periodYear == nil })
        #expect(fetchedTemplate.periodMonth == nil) // 与 periodYear 同空同有
        #expect(fetchedTemplate.categoryID == nil)  // nil = 总预算
        #expect(fetchedTemplate.ledgerID == ledgerID)
    }

    @Test func 授信池往返() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let pool = StoredCreditPool(name: "招商银行", totalLimitMinorUnits: 10_000_000)
        context.insert(pool)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<StoredCreditPool>()).first)
        #expect(fetched.name == "招商银行")
        #expect(fetched.totalLimitMinorUnits == 10_000_000)
        #expect(fetched.currencyCode == "CNY")
        #expect(fetched.note.isEmpty)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `xcodebuild test -project zanzan.xcodeproj -scheme zanzan -only-testing:zanzanTests -destination 'platform=iOS Simulator,name=iPhone 17' -quiet`
Expected: 编译失败——`cannot find 'StoredTransactionLink' in scope` 等。

- [ ] **Step 3: 实现三模型并注册**

```swift
// zanzan/Core/Models/StoredTransactionLink.swift
import Foundation
import SwiftData

/// 流水关联——报销/退款分摊，一行 = 一次分摊，M:N（数据库设计文档 5.5）。
/// 双向反查各建一索引。
@Model
final class StoredTransactionLink {
    #Index<StoredTransactionLink>([\.originalTransactionID], [\.settlementTransactionID])

    var uuid: UUID = UUID()
    var originalTransactionID: UUID = UUID()
    var settlementTransactionID: UUID = UUID()
    var kindRawValue: String = ""
    var amountMinorUnits: Int = 0 // 本次分摊金额，以原单币种计
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    var kind: TransactionLinkKind? { TransactionLinkKind(rawValue: kindRawValue) }

    init(
        originalTransactionID: UUID,
        settlementTransactionID: UUID,
        kind: TransactionLinkKind,
        amountMinorUnits: Int
    ) {
        self.originalTransactionID = originalTransactionID
        self.settlementTransactionID = settlementTransactionID
        self.kindRawValue = kind.rawValue
        self.amountMinorUnits = amountMinorUnits
    }
}
```

```swift
// zanzan/Core/Models/StoredBudget.swift
import Foundation
import SwiftData

/// 预算——模板行（periodYear/periodMonth 为 nil）+ 按月实体行（数据库设计文档 5.7）。
/// 已用额由投影器实时汇总，不落库；金额以本位币计。
@Model
final class StoredBudget {
    var uuid: UUID = UUID()
    var ledgerID: UUID = UUID() // 预算必挂账本，init 注入
    var categoryID: UUID? = nil // nil = 总预算
    var periodYear: Int? = nil  // nil = 模板行
    var periodMonth: Int? = nil // 与 periodYear 同空同有（命令层保证）
    var amountMinorUnits: Int = 0
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(ledgerID: UUID, amountMinorUnits: Int) {
        self.ledgerID = ledgerID
        self.amountMinorUnits = amountMinorUnits
    }
}
```

```swift
// zanzan/Core/Models/StoredCreditPool.swift
import Foundation
import SwiftData

/// 银行授信池——多卡共享额度（数据库设计文档 5.8）。
/// 成员关系由 StoredAccount.creditPoolID 反向表达；已用/可用额度全部派生不落库。
@Model
final class StoredCreditPool {
    #Index<StoredCreditPool>([\.uuid])

    var uuid: UUID = UUID()
    var name: String = ""
    var totalLimitMinorUnits: Int = 0
    var currencyCode: String = "CNY"
    var iconKindRawValue: String = ""
    var iconPrimary: String = ""
    var iconSecondary: String = ""
    var iconIndex: Int = 0
    var note: String = ""
    var sortOrder: Int = 0
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(name: String, totalLimitMinorUnits: Int) {
        self.name = name
        self.totalLimitMinorUnits = totalLimitMinorUnits
    }
}
```

`SchemaV1.models` 数组追加（`StoredTag.self` 之后）：

```swift
            StoredTransactionLink.self,
            StoredBudget.self,
            StoredCreditPool.self,
```

- [ ] **Step 4: 跑测试确认通过**

Run: 同 Step 2 命令
Expected: PASS（新增 3 例）。

- [ ] **Step 5: Commit**

```bash
git add zanzan/Core/Models/StoredTransactionLink.swift zanzan/Core/Models/StoredBudget.swift zanzan/Core/Models/StoredCreditPool.swift zanzan/Core/Models/SchemaV1.swift zanzanTests/CoreDomainSchemaTests.swift
git commit -m "$(printf '%s\n' '✨ feat(core): 建入流水关联/预算/授信池表' '' '- transaction link rows with bidirectional lookup indexes' '- budget template vs monthly rows via nullable period columns' '- credit pool with derived-only usage semantics' '' 'Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 5: 负债域——StoredInstallmentPlan / StoredInstallmentPeriod

**Files:**
- Create: `zanzan/Core/Models/StoredInstallmentPlan.swift`
- Create: `zanzan/Core/Models/StoredInstallmentPeriod.swift`
- Modify: `zanzan/Core/Models/SchemaV1.swift`（models 数组追加两项）
- Test: `zanzanTests/InstallmentSchemaTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `InstallmentPlanKind` / `AmortizationKind` / `InstallmentPlanStatus` / `InstallmentPeriodStatus`。
- Produces:
  - `StoredInstallmentPlan(name: String, kind: InstallmentPlanKind, accountID: UUID, ledgerID: UUID, principalMinorUnits: Int, totalPeriods: Int, amortizationKind: AmortizationKind, firstDueAt: Date)`，含 `kind` / `amortizationKind` / `status` 计算属性。
  - `StoredInstallmentPeriod(planID: UUID, periodIndex: Int, dueAt: Date, principalMinorUnits: Int, interestMinorUnits: Int)`，含 `status` 计算属性。

- [ ] **Step 1: 写失败测试**

```swift
// zanzanTests/InstallmentSchemaTests.swift
import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct InstallmentSchemaTests {
    @Test func 分期计划往返与状态默认值() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let plan = StoredInstallmentPlan(
            name: "iPhone 24 期",
            kind: .purchase,
            accountID: UUID(),
            ledgerID: UUID(),
            principalMinorUnits: 999_900,
            totalPeriods: 24,
            amortizationKind: .flatFee,
            firstDueAt: .now
        )
        context.insert(plan)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<StoredInstallmentPlan>()).first)
        #expect(fetched.kind == .purchase)
        #expect(fetched.amortizationKind == .flatFee)
        #expect(fetched.status == .active)
        #expect(fetched.annualRateBps == nil) // 固定手续费类分期无年利率
        #expect(fetched.closedAt == nil)
        #expect(!fetched.isAutoSettle)
        #expect(fetched.totalPeriods == 24)
    }

    @Test func 期数行往返与回填字段() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let planID = UUID()
        let period = StoredInstallmentPeriod(
            planID: planID,
            periodIndex: 1,
            dueAt: .now,
            principalMinorUnits: 41_663,
            interestMinorUnits: 2_500
        )
        context.insert(period)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<StoredInstallmentPeriod>()).first)
        #expect(fetched.planID == planID)
        #expect(fetched.periodIndex == 1)
        #expect(fetched.status == .pending)
        #expect(fetched.settledAt == nil)
        #expect(fetched.settledTransactionID == nil)
    }

    @Test func 按计划与期序谓词查询() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let planID = UUID()
        for index in 1...3 {
            context.insert(StoredInstallmentPeriod(
                planID: planID, periodIndex: index, dueAt: .now,
                principalMinorUnits: 100, interestMinorUnits: 0
            ))
        }
        context.insert(StoredInstallmentPeriod(
            planID: UUID(), periodIndex: 1, dueAt: .now,
            principalMinorUnits: 100, interestMinorUnits: 0
        ))
        try context.save()

        let descriptor = FetchDescriptor<StoredInstallmentPeriod>(
            predicate: #Predicate { $0.planID == planID },
            sortBy: [SortDescriptor(\.periodIndex)]
        )
        let fetched = try context.fetch(descriptor)
        #expect(fetched.count == 3)
        #expect(fetched.map(\.periodIndex) == [1, 2, 3])
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `xcodebuild test -project zanzan.xcodeproj -scheme zanzan -only-testing:zanzanTests -destination 'platform=iOS Simulator,name=iPhone 17' -quiet`
Expected: 编译失败——`cannot find 'StoredInstallmentPlan' in scope` 等。

- [ ] **Step 3: 实现两模型并注册**

```swift
// zanzan/Core/Models/StoredInstallmentPlan.swift
import Foundation
import SwiftData

/// 分期/贷款合同（数据库设计文档 5.9）。余额记已发生事实，计划只记日程与进度；
/// 已还期数/剩余本金/应付总利息全部由期表派生，不落库。
@Model
final class StoredInstallmentPlan {
    #Index<StoredInstallmentPlan>([\.uuid])

    var uuid: UUID = UUID()
    var name: String = ""
    var kindRawValue: String = ""
    var accountID: UUID = UUID() // 债务账户：分期→credit，贷款→payable（命令层校验）
    var ledgerID: UUID = UUID()  // 产出还款流水的归属账本
    var principalMinorUnits: Int = 0
    var totalPeriods: Int = 0
    var annualRateBps: Int? = nil // 固定手续费类分期为 nil
    var amortizationKindRawValue: String = ""
    var firstDueAt: Date = Date.now
    var isAutoSettle: Bool = false
    var statusRawValue: String = "active"
    var closedAt: Date? = nil
    var note: String = ""
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    var kind: InstallmentPlanKind? { InstallmentPlanKind(rawValue: kindRawValue) }
    var amortizationKind: AmortizationKind? { AmortizationKind(rawValue: amortizationKindRawValue) }
    var status: InstallmentPlanStatus? { InstallmentPlanStatus(rawValue: statusRawValue) }

    init(
        name: String,
        kind: InstallmentPlanKind,
        accountID: UUID,
        ledgerID: UUID,
        principalMinorUnits: Int,
        totalPeriods: Int,
        amortizationKind: AmortizationKind,
        firstDueAt: Date
    ) {
        self.name = name
        self.kindRawValue = kind.rawValue
        self.accountID = accountID
        self.ledgerID = ledgerID
        self.principalMinorUnits = principalMinorUnits
        self.totalPeriods = totalPeriods
        self.amortizationKindRawValue = amortizationKind.rawValue
        self.firstDueAt = firstDueAt
    }
}
```

```swift
// zanzan/Core/Models/StoredInstallmentPeriod.swift
import Foundation
import SwiftData

/// 分期期数——一期一行，建计划时全量物化（数据库设计文档 5.10）。
/// 期表行是唯一真相，amortizationKind 仅作再生成/展示元数据。
@Model
final class StoredInstallmentPeriod {
    #Index<StoredInstallmentPeriod>([\.planID, \.periodIndex])

    var uuid: UUID = UUID()
    var planID: UUID = UUID()
    var periodIndex: Int = 0 // 期序，1 起
    var dueAt: Date = Date.now
    var principalMinorUnits: Int = 0
    var interestMinorUnits: Int = 0
    var statusRawValue: String = "pending"
    var settledAt: Date? = nil
    var settledTransactionID: UUID? = nil
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    var status: InstallmentPeriodStatus? { InstallmentPeriodStatus(rawValue: statusRawValue) }

    init(planID: UUID, periodIndex: Int, dueAt: Date, principalMinorUnits: Int, interestMinorUnits: Int) {
        self.planID = planID
        self.periodIndex = periodIndex
        self.dueAt = dueAt
        self.principalMinorUnits = principalMinorUnits
        self.interestMinorUnits = interestMinorUnits
    }
}
```

`SchemaV1.models` 数组追加（`StoredCreditPool.self` 之后）：

```swift
            StoredInstallmentPlan.self,
            StoredInstallmentPeriod.self,
```

- [ ] **Step 4: 跑测试确认通过**

Run: 同 Step 2 命令
Expected: PASS（新增 3 例）。

- [ ] **Step 5: Commit**

```bash
git add zanzan/Core/Models/StoredInstallmentPlan.swift zanzan/Core/Models/StoredInstallmentPeriod.swift zanzan/Core/Models/SchemaV1.swift zanzanTests/InstallmentSchemaTests.swift
git commit -m "$(printf '%s\n' '✨ feat(core): 建入分期计划与期数表' '' '- installment plan contract with derived-only progress semantics' '- one row per period with (planID, periodIndex) compound index' '' 'Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 6: 自动化与辅助域收尾 + 15 表完整性

**Files:**
- Create: `zanzan/Core/Models/StoredRecurringRule.swift`
- Create: `zanzan/Core/Models/StoredImportBatch.swift`
- Create: `zanzan/Core/Models/StoredBalanceSnapshot.swift`
- Create: `zanzan/Core/Models/StoredAuditLog.swift`
- Create: `zanzan/Core/Models/StoredMeta.swift`
- Modify: `zanzan/Core/Models/SchemaV1.swift`（models 数组追加五项，达 15）
- Test: `zanzanTests/SupportSchemaTests.swift`
- Modify: `zanzanTests/SchemaV1Tests.swift`（追加 15 表登记断言）

**Interfaces:**
- Consumes: Task 1 的 `RecurrenceFrequency` / `TransactionKind`。
- Produces:
  - `StoredRecurringRule(name: String, frequency: RecurrenceFrequency, startAt: Date, nextRunAt: Date, templateKind: TransactionKind, templateAmountMinorUnits: Int)`，含 `frequency` / `templateKind` 计算属性。
  - `StoredImportBatch(fileName: String, importedAt: Date)`。
  - `StoredBalanceSnapshot(accountID: UUID, snapshotAt: Date, balanceMinorUnits: Int)`。
  - `StoredAuditLog(action: String, detail: String = "")`。
  - `StoredMeta(key: String, value: String)`。

- [ ] **Step 1: 写失败测试**

```swift
// zanzanTests/SupportSchemaTests.swift
import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct SupportSchemaTests {
    @Test func 周期规则Codable数组往返() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let tagIDs = [UUID(), UUID()]
        let rule = StoredRecurringRule(
            name: "房租",
            frequency: .monthly,
            startAt: .now,
            nextRunAt: .now,
            templateKind: .expense,
            templateAmountMinorUnits: 350_000
        )
        rule.recurrenceDays = [1, 15, 31]
        rule.templateTagIDs = tagIDs
        context.insert(rule)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<StoredRecurringRule>()).first)
        #expect(fetched.frequency == .monthly)
        #expect(fetched.interval == 1)
        #expect(fetched.recurrenceDays == [1, 15, 31])
        #expect(fetched.templateTagIDs == tagIDs)
        #expect(fetched.templateKind == .expense)
        #expect(fetched.endAt == nil)
        #expect(!fetched.isPaused)
    }

    @Test func 导入批次往返() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let batch = StoredImportBatch(fileName: "alipay-2026-06.csv", importedAt: .now)
        batch.contentHash = "abc123"
        batch.transactionCount = 42
        context.insert(batch)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<StoredImportBatch>()).first)
        #expect(fetched.fileName == "alipay-2026-06.csv")
        #expect(fetched.contentHash == "abc123")
        #expect(fetched.transactionCount == 42)
    }

    @Test func 余额检查点含汇率快照往返() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let accountID = UUID()
        let snapshot = StoredBalanceSnapshot(
            accountID: accountID, snapshotAt: .now, balanceMinorUnits: 123_456
        )
        snapshot.fxRateToBase = Decimal(string: "7.18")
        context.insert(snapshot)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<StoredBalanceSnapshot>()).first)
        #expect(fetched.accountID == accountID)
        #expect(fetched.balanceMinorUnits == 123_456)
        #expect(fetched.fxRateToBase == Decimal(string: "7.18"))
    }

    @Test func 操作日志与元数据往返() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        context.insert(StoredAuditLog(action: "accountDelete", detail: "招行卡"))
        context.insert(StoredMeta(key: "schemaVersion", value: "1.0.0"))
        try context.save()

        let log = try #require(try context.fetch(FetchDescriptor<StoredAuditLog>()).first)
        #expect(log.action == "accountDelete")
        #expect(log.detail == "招行卡")

        let meta = try #require(try context.fetch(FetchDescriptor<StoredMeta>()).first)
        #expect(meta.key == "schemaVersion")
        #expect(meta.value == "1.0.0")
    }
}
```

`zanzanTests/SchemaV1Tests.swift` 追加一例：

```swift
    @Test func SchemaV1登记全部15张表() {
        #expect(SchemaV1.models.count == 15)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `xcodebuild test -project zanzan.xcodeproj -scheme zanzan -only-testing:zanzanTests -destination 'platform=iOS Simulator,name=iPhone 17' -quiet`
Expected: 编译失败——`cannot find 'StoredRecurringRule' in scope` 等。

- [ ] **Step 3: 实现五模型并注册**

```swift
// zanzan/Core/Models/StoredRecurringRule.swift
import Foundation
import SwiftData

/// 周期记账——规则字段 + 类型化模板字段（数据库设计文档 5.11）。
/// 管「无本金概念的重复模板流水」，与分期计划互不依赖。
@Model
final class StoredRecurringRule {
    var uuid: UUID = UUID()
    // 规则
    var name: String = ""
    var frequencyRawValue: String = ""
    var interval: Int = 1
    var recurrenceDays: [Int] = [] // 值大于当月天数时取月末（命令层实现）
    var startAt: Date = Date.now
    var endAt: Date? = nil
    var nextRunAt: Date = Date.now
    var isPaused: Bool = false
    // 模板（TransactionDraft 的持久化子集）
    var templateKindRawValue: String = ""
    var templateLedgerID: UUID? = nil // 命令层保证非空，与流水 ledgerID 同口径
    var templateAmountMinorUnits: Int = 0
    var templateAccountID: UUID? = nil
    var templateTargetAccountID: UUID? = nil
    var templateCategoryID: UUID? = nil
    var templateTagIDs: [UUID] = []
    var templateNote: String = ""
    // 通用
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    var frequency: RecurrenceFrequency? { RecurrenceFrequency(rawValue: frequencyRawValue) }
    var templateKind: TransactionKind? { TransactionKind(rawValue: templateKindRawValue) }

    init(
        name: String,
        frequency: RecurrenceFrequency,
        startAt: Date,
        nextRunAt: Date,
        templateKind: TransactionKind,
        templateAmountMinorUnits: Int
    ) {
        self.name = name
        self.frequencyRawValue = frequency.rawValue
        self.startAt = startAt
        self.nextRunAt = nextRunAt
        self.templateKindRawValue = templateKind.rawValue
        self.templateAmountMinorUnits = templateAmountMinorUnits
    }
}
```

```swift
// zanzan/Core/Models/StoredImportBatch.swift
import Foundation
import SwiftData

/// 导入批次——误导入按批次反查、整批软删（数据库设计文档 5.12）
@Model
final class StoredImportBatch {
    var uuid: UUID = UUID()
    var fileName: String = ""
    var contentHash: String = "" // SHA-256，命令层撞哈希时警告疑似重复导入
    var transactionCount: Int = 0
    var importedAt: Date = Date.now
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(fileName: String, importedAt: Date) {
        self.fileName = fileName
        self.importedAt = importedAt
    }
}
```

```swift
// zanzan/Core/Models/StoredBalanceSnapshot.swift
import Foundation
import SwiftData

/// 账户余额检查点——可整体重建的缓存，删光重算逐分一致（数据库设计文档 5.13）
@Model
final class StoredBalanceSnapshot {
    #Index<StoredBalanceSnapshot>([\.accountID, \.snapshotAt])

    var uuid: UUID = UUID()
    var accountID: UUID = UUID()
    var snapshotAt: Date = Date.now
    var balanceMinorUnits: Int = 0 // 账户币种计
    var fxRateToBase: Decimal? = nil // 快照时点汇率；CNY 账户为 nil
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(accountID: UUID, snapshotAt: Date, balanceMinorUnits: Int) {
        self.accountID = accountID
        self.snapshotAt = snapshotAt
        self.balanceMinorUnits = balanceMinorUnits
    }
}
```

```swift
// zanzan/Core/Models/StoredAuditLog.swift
import Foundation
import SwiftData

/// 操作日志——只追加不更新，滚动保留由维护命令清理（数据库设计文档 5.14）
@Model
final class StoredAuditLog {
    var uuid: UUID = UUID()
    var action: String = ""
    var detail: String = ""
    var occurredAt: Date = Date.now
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(action: String, detail: String = "") {
        self.action = action
        self.detail = detail
    }
}
```

```swift
// zanzan/Core/Models/StoredMeta.swift
import Foundation
import SwiftData

/// 库级元数据键值——用途锁死为系统标记，业务数据禁入（数据库设计文档 5.15）
@Model
final class StoredMeta {
    var uuid: UUID = UUID()
    var key: String = ""
    var value: String = ""
    var isSoftDeleted: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}
```

`zanzan/Core/Models/SchemaV1.swift` 最终形态：

```swift
import Foundation
import SwiftData

/// 版本登记簿 V1（数据库设计文档 13.1）——全部 15 张表
enum SchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            StoredLedger.self,
            StoredAccount.self,
            StoredCategory.self,
            StoredTransaction.self,
            StoredTag.self,
            StoredTransactionLink.self,
            StoredBudget.self,
            StoredCreditPool.self,
            StoredInstallmentPlan.self,
            StoredInstallmentPeriod.self,
            StoredRecurringRule.self,
            StoredImportBatch.self,
            StoredBalanceSnapshot.self,
            StoredAuditLog.self,
            StoredMeta.self,
        ]
    }
}
```

- [ ] **Step 4: 跑全量测试确认通过（含 UI 启动测试）**

Run: `xcodebuild test -project zanzan.xcodeproj -scheme zanzan -destination 'platform=iOS Simulator,name=iPhone 17' -quiet`
Expected: PASS——zanzanTests 全绿 + zanzanUITests 冷启动不 crash（15 表容器装配成功）。

- [ ] **Step 5: Commit**

```bash
git add zanzan/Core/Models/StoredRecurringRule.swift zanzan/Core/Models/StoredImportBatch.swift zanzan/Core/Models/StoredBalanceSnapshot.swift zanzan/Core/Models/StoredAuditLog.swift zanzan/Core/Models/StoredMeta.swift zanzan/Core/Models/SchemaV1.swift zanzanTests/SupportSchemaTests.swift zanzanTests/SchemaV1Tests.swift
git commit -m "$(printf '%s\n' '✨ feat(core): 建入自动化与辅助表并完成 15 表登记' '' '- recurring rule with typed template columns and codable arrays' '- import batch, balance snapshot, audit log, meta key-value' '- SchemaV1 now registers all fifteen tables per design doc' '' 'Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## 完成定义

- `SchemaV1.models` 登记全部 15 张表，与设计文档 §3 全表清单一一对应；模型代码逐字段对齐 §5 表结构（含默认值、可空性、索引）。
- 全部关系显式声明 inverse 且可空、无 `#Unique`、全字段有声明处默认值——CloudKit 红线（§13.2）静态满足。
- 流水自带派生 `signedMinorUnits` / `balanceDeltaMinorUnits(for:)` 有测试覆盖（含 fee 与跨币种口径、未知类型兜底）。
- `xcodebuild test`（全 target）绿。
- 刻意不做（后续切片再建，非遗漏）：`*Draft` / `*Commands` / `*Projector` / `DefaultDataSeeder` / `MoneyAmount` / CSV 导入导出 / schema 指纹测试与夹具迁移测试（§13.5，首个 SchemaV2 出现时一并落地）/ `StoredMeta.schemaVersion` 启动写入逻辑（属命令层）。
