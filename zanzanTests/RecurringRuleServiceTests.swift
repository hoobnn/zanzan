import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct RecurringRuleServiceTests {
    /// 建好账本/账户/分类/标签的公共夹具
    @MainActor
    private struct Fixture {
        let context: ModelContext
        let ledger: Ledger
        let cash: Account
        let card: Account
        let dining: Category   // expense
        let salary: Category   // income
        let tag: Tag

        var service: RecurringRuleService { RecurringRuleService(context: context) }
    }

    private func makeFixture() throws -> Fixture {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let ledger = try LedgerService(context: context).createLedger(LedgerDraft(name: "日常"))
        let cash = Account(name: "现金", kind: .fund)
        let card = Account(name: "储蓄卡", kind: .fund)
        let dining = Category(name: "餐饮", kind: .expense, sortOrder: 0)
        let salary = Category(name: "工资", kind: .income, sortOrder: 0)
        let tag = Tag(name: "固定支出")
        context.insert(cash)
        context.insert(card)
        context.insert(dining)
        context.insert(salary)
        context.insert(tag)
        try context.save()
        return Fixture(context: context, ledger: ledger, cash: cash, card: card, dining: dining, salary: salary, tag: tag)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 9) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// 默认：月频支出草稿（现金/餐饮，35 元）
    private func makeDraft(
        _ f: Fixture, startAt: Date, frequency: RecurrenceFrequency = .monthly,
        interval: Int = 1, days: [Int] = [], endAt: Date? = nil
    ) -> RecurringRuleDraft {
        var draft = RecurringRuleDraft(startAt: startAt, templateLedgerID: f.ledger.uuid)
        draft.name = "房租"
        draft.frequency = frequency
        draft.interval = interval
        draft.recurrenceDays = days
        draft.endAt = endAt
        draft.amountString = "35"
        draft.templateKind = .expense
        draft.templateAccountID = f.cash.uuid
        draft.templateCategoryID = f.dining.uuid
        return draft
    }

    private func transactionCount(_ f: Fixture) throws -> Int {
        try f.context.fetchCount(FetchDescriptor<Transaction>())
    }

    // MARK: - 创建 / 更新

    @Test func 创建规则落库并算出下次触发() throws {
        let f = try makeFixture()
        var draft = makeDraft(f, startAt: date(2026, 7, 1), days: [5])
        draft.templateTagIDs = [f.tag.uuid]
        let rule = try f.service.createRule(draft)
        #expect(rule.frequency == .monthly)
        #expect(rule.recurrenceDays == [5])
        #expect(rule.nextRunAt == date(2026, 7, 5)) // 推进到首个触发日，时分秒取 startAt
        #expect(rule.templateLedgerID == f.ledger.uuid)
        #expect(rule.templateAmountMinorUnits == 3_500)
        #expect(rule.templateTagIDs == [f.tag.uuid])
        #expect(!rule.isPaused)
        #expect(!rule.isSoftDeleted)
    }

    @Test func 创建时startAt当日即触发日() throws {
        let f = try makeFixture()
        let rule = try f.service.createRule(makeDraft(f, startAt: date(2026, 7, 5)))
        #expect(rule.nextRunAt == date(2026, 7, 5))
    }

    @Test func 创建时账本不存在被拒() throws {
        let f = try makeFixture()
        var draft = makeDraft(f, startAt: date(2026, 7, 5))
        draft.templateLedgerID = UUID()
        #expect(throws: RecurringRuleServiceError.self) { try f.service.createRule(draft) }
    }

    @Test func 创建时分类方向不匹配被拒() throws {
        let f = try makeFixture()
        var draft = makeDraft(f, startAt: date(2026, 7, 5))
        draft.templateCategoryID = f.salary.uuid // 支出挂收入分类
        #expect(throws: RecurringRuleServiceError.self) { try f.service.createRule(draft) }
    }

    @Test func 创建时账户不存在被拒() throws {
        let f = try makeFixture()
        var draft = makeDraft(f, startAt: date(2026, 7, 5))
        draft.templateAccountID = UUID()
        #expect(throws: RecurringRuleServiceError.self) { try f.service.createRule(draft) }
    }

    @Test func 创建时标签不存在被拒() throws {
        let f = try makeFixture()
        var draft = makeDraft(f, startAt: date(2026, 7, 5))
        draft.templateTagIDs = [UUID()]
        #expect(throws: RecurringRuleServiceError.self) { try f.service.createRule(draft) }
    }

    @Test func 创建时截止前无触发日被拒() throws {
        let f = try makeFixture()
        let draft = makeDraft(f, startAt: date(2026, 7, 1), days: [5], endAt: date(2026, 7, 3))
        #expect(throws: RecurringRuleServiceError.self) { try f.service.createRule(draft) }
    }

    @Test func 更新规则从asOf起按新计划触发不回填过去() throws {
        let f = try makeFixture()
        let rule = try f.service.createRule(makeDraft(f, startAt: date(2026, 5, 1), days: [5]))
        let backfilled = try f.service.materializeDue(asOf: date(2026, 6, 10)).created
        #expect(backfilled.count == 2) // 5/5、6/5

        var draft = makeDraft(f, startAt: date(2026, 5, 1), days: [20])
        draft.amountString = "50"
        try f.service.updateRule(uuid: rule.uuid, draft: draft, asOf: date(2026, 6, 10))
        #expect(rule.nextRunAt == date(2026, 6, 20)) // 新触发日，且不回填 5/20
        #expect(rule.templateAmountMinorUnits == 5_000)

        let created = try f.service.materializeDue(asOf: date(2026, 6, 25)).created
        #expect(created.count == 1)
        #expect(created[0].occurredAt == date(2026, 6, 20))
        #expect(created[0].amountMinorUnits == 5_000)
    }

    @Test func 软删规则后不可更新() throws {
        let f = try makeFixture()
        let rule = try f.service.createRule(makeDraft(f, startAt: date(2026, 7, 5)))
        try f.service.softDeleteRule(uuid: rule.uuid)
        #expect(rule.isSoftDeleted)
        #expect(throws: RecurringRuleServiceError.self) {
            try f.service.updateRule(uuid: rule.uuid, draft: self.makeDraft(f, startAt: self.date(2026, 7, 5)), asOf: self.date(2026, 7, 5))
        }
    }

    // MARK: - materializeDue 成功路径

    @Test func 到期生成流水字段齐全() throws {
        let f = try makeFixture()
        var draft = makeDraft(f, startAt: date(2026, 7, 5))
        draft.templateTagIDs = [f.tag.uuid]
        draft.templateNote = "七月房租"
        let rule = try f.service.createRule(draft)

        let created = try f.service.materializeDue(asOf: date(2026, 7, 5, hour: 10)).created

        #expect(created.count == 1)
        let tx = created[0]
        #expect(tx.kind == .expense)
        #expect(tx.amountMinorUnits == 3_500)
        #expect(tx.occurredAt == date(2026, 7, 5)) // occurredAt 取应发日
        #expect(tx.ledgerID == f.ledger.uuid)
        #expect(tx.account?.uuid == f.cash.uuid)
        #expect(tx.category?.uuid == f.dining.uuid)
        #expect(tx.note == "七月房租")
        #expect(tx.sourceKind == .recurring)
        #expect(tx.sourceID == rule.uuid)
        #expect(tx.tags?.map(\.uuid) == [f.tag.uuid])
        #expect(rule.nextRunAt == date(2026, 8, 5)) // 推进到下期
    }

    @Test func 未到期不生成() throws {
        let f = try makeFixture()
        let rule = try f.service.createRule(makeDraft(f, startAt: date(2026, 7, 5)))
        let created = try f.service.materializeDue(asOf: date(2026, 7, 4)).created
        #expect(created.isEmpty)
        #expect(rule.nextRunAt == date(2026, 7, 5)) // 不推进
    }

    @Test func 错过多期逐期补记() throws {
        let f = try makeFixture()
        let rule = try f.service.createRule(makeDraft(f, startAt: date(2026, 5, 1), days: [5]))
        let created = try f.service.materializeDue(asOf: date(2026, 7, 10)).created
        #expect(created.count == 3) // 每期一笔
        #expect(created.map(\.occurredAt) == [date(2026, 5, 5), date(2026, 6, 5), date(2026, 7, 5)])
        #expect(rule.nextRunAt == date(2026, 8, 5))
    }

    @Test func 转账规则生成转账流水() throws {
        let f = try makeFixture()
        var draft = makeDraft(f, startAt: date(2026, 7, 5))
        draft.templateKind = .transfer
        draft.templateCategoryID = nil
        draft.templateTargetAccountID = f.card.uuid
        try f.service.createRule(draft)

        let created = try f.service.materializeDue(asOf: date(2026, 7, 5)).created

        #expect(created.count == 1)
        #expect(created[0].kind == .transfer)
        #expect(created[0].account?.uuid == f.cash.uuid)
        #expect(created[0].targetAccount?.uuid == f.card.uuid)
        #expect(created[0].category == nil)
    }

    // MARK: - 幂等

    @Test func 重复调用不重复生成() throws {
        let f = try makeFixture()
        try f.service.createRule(makeDraft(f, startAt: date(2026, 5, 1), days: [5]))
        let first = try f.service.materializeDue(asOf: date(2026, 7, 10)).created
        let second = try f.service.materializeDue(asOf: date(2026, 7, 10)).created
        #expect(first.count == 3)
        #expect(second.isEmpty)
        #expect(try transactionCount(f) == 3)
    }

    @Test func 崩溃重放按应发日去重不产生重复() throws {
        let f = try makeFixture()
        let rule = try f.service.createRule(makeDraft(f, startAt: date(2026, 7, 5)))
        let first = try f.service.materializeDue(asOf: date(2026, 7, 10)).created
        #expect(first.count == 1)

        // 模拟"流水已落库但 nextRunAt 未推进"的崩溃现场
        rule.nextRunAt = date(2026, 7, 5)
        try f.context.save()

        let replay = try f.service.materializeDue(asOf: date(2026, 7, 10)).created
        #expect(replay.isEmpty) // (sourceID, occurredAt) 去重兜底
        #expect(try transactionCount(f) == 1)
        #expect(rule.nextRunAt == date(2026, 8, 5)) // 仍正常推进
    }

    @Test func 软删产出后补记不复活() throws {
        let f = try makeFixture()
        let rule = try f.service.createRule(makeDraft(f, startAt: date(2026, 7, 5)))
        let first = try f.service.materializeDue(asOf: date(2026, 7, 10)).created
        try TransactionService(context: f.context).softDeleteTransaction(uuid: first[0].uuid)

        rule.nextRunAt = date(2026, 7, 5) // 重走该期
        try f.context.save()
        let replay = try f.service.materializeDue(asOf: date(2026, 7, 10)).created

        #expect(replay.isEmpty) // 用户删除即否决该期
        #expect(try transactionCount(f) == 1)
    }

    // MARK: - 暂停 / 软删 / 截止边界

    @Test func 暂停规则不生成() throws {
        let f = try makeFixture()
        let rule = try f.service.createRule(makeDraft(f, startAt: date(2026, 7, 5)))
        try f.service.pauseRule(uuid: rule.uuid)
        let created = try f.service.materializeDue(asOf: date(2026, 8, 10)).created
        #expect(created.isEmpty)
        #expect(rule.nextRunAt == date(2026, 7, 5)) // 暂停期间不推进
    }

    @Test func 恢复跳过暂停期间错过的各期() throws {
        let f = try makeFixture()
        let rule = try f.service.createRule(makeDraft(f, startAt: date(2026, 5, 5)))
        #expect(try f.service.materializeDue(asOf: date(2026, 5, 5)).created.count == 1)

        try f.service.pauseRule(uuid: rule.uuid)
        try f.service.resumeRule(uuid: rule.uuid, asOf: date(2026, 7, 10))

        #expect(!rule.isPaused)
        #expect(rule.nextRunAt == date(2026, 8, 5)) // 6/5、7/5 跳过
        #expect(try f.service.materializeDue(asOf: date(2026, 7, 10)).created.isEmpty)
    }

    @Test func 软删规则不生成() throws {
        let f = try makeFixture()
        let rule = try f.service.createRule(makeDraft(f, startAt: date(2026, 7, 5)))
        try f.service.softDeleteRule(uuid: rule.uuid)
        let created = try f.service.materializeDue(asOf: date(2026, 8, 10)).created
        #expect(created.isEmpty)
        #expect(try transactionCount(f) == 0)
    }

    @Test func 截止之后不再生成() throws {
        let f = try makeFixture()
        try f.service.createRule(makeDraft(f, startAt: date(2026, 5, 5), endAt: date(2026, 6, 30)))
        let created = try f.service.materializeDue(asOf: date(2026, 9, 1)).created
        #expect(created.count == 2) // 5/5、6/5；7/5 起已过截止
        #expect(created.map(\.occurredAt) == [date(2026, 5, 5), date(2026, 6, 5)])
    }

    // MARK: - 短月与频率边界

    @Test func 月频31号短月收缩到月末() throws {
        let f = try makeFixture()
        try f.service.createRule(makeDraft(f, startAt: date(2026, 1, 31), days: [31]))
        let created = try f.service.materializeDue(asOf: date(2026, 3, 31, hour: 23)).created
        // 2026 非闰年：1/31、2/28（收缩）、3/31
        #expect(created.map(\.occurredAt) == [date(2026, 1, 31), date(2026, 2, 28), date(2026, 3, 31)])
    }

    @Test func 短月多触发日收缩重合只生成一笔() throws {
        let f = try makeFixture()
        try f.service.createRule(makeDraft(f, startAt: date(2026, 2, 1), days: [30, 31]))
        let created = try f.service.materializeDue(asOf: date(2026, 3, 31, hour: 23)).created
        // 2 月 30/31 同缩到 28 只记一笔；3 月恢复两笔
        #expect(created.map(\.occurredAt) == [date(2026, 2, 28), date(2026, 3, 30), date(2026, 3, 31)])
    }

    @Test func 周频多触发日逐周生成() throws {
        let f = try makeFixture()
        // 2026-07-06 为周一；周一(2)/周五(6) 各触发一次
        try f.service.createRule(makeDraft(f, startAt: date(2026, 7, 6), frequency: .weekly, days: [2, 6]))
        let created = try f.service.materializeDue(asOf: date(2026, 7, 17, hour: 23)).created
        #expect(created.map(\.occurredAt) == [
            date(2026, 7, 6), date(2026, 7, 10), date(2026, 7, 13), date(2026, 7, 17),
        ])
    }

    @Test func 月频间隔2隔月生成() throws {
        let f = try makeFixture()
        try f.service.createRule(makeDraft(f, startAt: date(2026, 1, 5), interval: 2))
        let created = try f.service.materializeDue(asOf: date(2026, 5, 31)).created
        #expect(created.map(\.occurredAt) == [date(2026, 1, 5), date(2026, 3, 5), date(2026, 5, 5)])
    }

    @Test func 日频间隔10逐期生成() throws {
        let f = try makeFixture()
        try f.service.createRule(makeDraft(f, startAt: date(2026, 7, 1), frequency: .daily, interval: 10))
        let created = try f.service.materializeDue(asOf: date(2026, 7, 21)).created
        #expect(created.map(\.occurredAt) == [date(2026, 7, 1), date(2026, 7, 11), date(2026, 7, 21)])
    }

    // MARK: - 多币种边界

    private func makeUSDAccount(_ f: Fixture) throws -> Account {
        let usd = Account(name: "美元卡", kind: .fund)
        usd.currencyCode = "USD"
        f.context.insert(usd)
        try f.context.save()
        return usd
    }

    @Test func 跨币种转账模板被拒() throws {
        let f = try makeFixture()
        let usd = try makeUSDAccount(f)
        var draft = makeDraft(f, startAt: date(2026, 7, 1))
        draft.templateKind = .transfer
        draft.templateCategoryID = nil
        draft.templateTargetAccountID = usd.uuid // 现金(CNY) → 美元卡，跨币种
        #expect(throws: RecurringRuleServiceError.self) {
            try f.service.createRule(draft)
        }
    }

    @Test func 单规则物化失败不炸整批且披露被跳过规则() throws {
        let f = try makeFixture()
        try f.service.createRule(makeDraft(f, startAt: date(2026, 7, 5)))
        // 坏规则：外币账户模板且全库无该币种汇率快照 → 物化时 missingFxRate
        let usd = try makeUSDAccount(f)
        var bad = makeDraft(f, startAt: date(2026, 7, 3))
        bad.name = "美元订阅"
        bad.templateAccountID = usd.uuid
        let badRule = try f.service.createRule(bad)
        let badNextRunAt = badRule.nextRunAt

        let outcome = try f.service.materializeDue(asOf: date(2026, 7, 10))
        // 坏规则被跳过（nextRunAt 不推进、下次重试），正常规则照常生成
        #expect(outcome.created.map(\.occurredAt) == [date(2026, 7, 5)])
        // 跳过的坏规则向调用方披露，不再静默僵尸
        #expect(outcome.skippedRules.map(\.ruleUUID) == [badRule.uuid])
        #expect(!outcome.skippedRules[0].message.isEmpty)
        #expect(badRule.nextRunAt == badNextRunAt) // 保持重试语义
    }

    @Test func 过期规则空转不回写不产生脏写() throws {
        let f = try makeFixture()
        let rule = try f.service.createRule(makeDraft(f, startAt: date(2026, 5, 5), endAt: date(2026, 5, 31)))
        #expect(try f.service.materializeDue(asOf: date(2026, 6, 10)).created.count == 1) // 5/5

        let updatedAt = rule.updatedAt
        let nextRunAt = rule.nextRunAt
        let outcome = try f.service.materializeDue(asOf: date(2026, 8, 1))

        #expect(outcome.created.isEmpty)
        #expect(outcome.skippedRules.isEmpty) // 过期不是错误，不算跳过
        #expect(rule.updatedAt == updatedAt) // 无进展不回写，避免 CloudKit 同步噪音
        #expect(rule.nextRunAt == nextRunAt)
    }

    // MARK: - 撤销恢复

    @Test func 撤销软删从asOf重算下次触发不补期() throws {
        let f = try makeFixture()
        let rule = try f.service.createRule(makeDraft(f, startAt: date(2026, 7, 1), days: [5]))
        try f.service.softDeleteRule(uuid: rule.uuid)
        try f.service.undoSoftDeleteRule(uuid: rule.uuid, asOf: date(2026, 9, 1))
        #expect(!rule.isSoftDeleted)
        #expect(rule.nextRunAt == date(2026, 9, 5)) // 删除期间的 7/5、8/5 不补
        let outcome = try f.service.materializeDue(asOf: date(2026, 9, 5))
        #expect(outcome.created.map(\.occurredAt) == [date(2026, 9, 5)])
    }

    @Test func 引用账户已删阻断恢复() throws {
        let f = try makeFixture()
        let rule = try f.service.createRule(makeDraft(f, startAt: date(2026, 7, 1), days: [5]))
        try f.service.softDeleteRule(uuid: rule.uuid)
        // 规则已软删不再算活跃引用，账户可删；随后恢复规则应被引用校验阻断
        try AccountService(context: f.context).softDeleteAccount(uuid: f.cash.uuid)
        #expect(throws: RecurringRuleServiceError.accountNotFound) {
            try f.service.undoSoftDeleteRule(uuid: rule.uuid, asOf: date(2026, 9, 1))
        }
        #expect(rule.isSoftDeleted)
    }

    @Test func 双重恢复幂等() throws {
        let f = try makeFixture()
        let rule = try f.service.createRule(makeDraft(f, startAt: date(2026, 7, 1), days: [5]))
        try f.service.softDeleteRule(uuid: rule.uuid)
        try f.service.undoSoftDeleteRule(uuid: rule.uuid, asOf: date(2026, 9, 1))
        try f.service.undoSoftDeleteRule(uuid: rule.uuid, asOf: date(2026, 9, 1))
        #expect(!rule.isSoftDeleted)
        #expect(rule.nextRunAt == date(2026, 9, 5))
    }
}
