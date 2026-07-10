import Foundation
import SwiftData

/// 周期记账写路径命令（设计文档 5.11）。不变量：
/// - 生成流水一律走 TransactionService 完整校验，打 sourceKind = recurring、sourceID = rule.uuid；
/// - 业务时间一律由参数注入（asOf:），逻辑层不取当前时钟；
/// - 触发日按设备当前日历口径；monthly 触发日大于当月天数时收缩到月末
///   （31 号规则在 2 月于 28/29 日触发），同月多触发日收缩重合时只触发一次；
/// - 触发时刻的时分秒取 startAt 的时分秒。
struct RecurringRuleService {
    let context: ModelContext

    private var calendar: Calendar { .current }

    // MARK: - 创建 / 更新

    @discardableResult
    func createRule(_ draft: RecurringRuleDraft) throws -> RecurringRule {
        let v = try draft.validated()
        try validateTemplateReferences(v)
        let next = try requiredFirstOccurrence(of: Schedule(v), onOrAfter: v.startAt)
        if let endAt = v.endAt, next > endAt { throw RecurringRuleServiceError.noOccurrenceBeforeEnd }
        let rule = RecurringRule(
            name: v.name, frequency: v.frequency, startAt: v.startAt, nextRunAt: next,
            templateKind: v.templateKind, templateAmountMinorUnits: v.templateAmountMinorUnits
        )
        apply(v, to: rule)
        context.insert(rule)
        try context.save()
        return rule
    }

    /// 更新规则：只影响未来——下次触发从 max(startAt, asOf) 起按新计划重算，不回填过去。
    func updateRule(uuid: UUID, draft: RecurringRuleDraft, asOf: Date) throws {
        let rule = try fetchActiveRule(uuid)
        let v = try draft.validated()
        try validateTemplateReferences(v)
        let next = try requiredFirstOccurrence(of: Schedule(v), onOrAfter: max(v.startAt, asOf))
        apply(v, to: rule)
        rule.nextRunAt = next
        rule.updatedAt = .now
        try context.save()
    }

    // MARK: - 暂停 / 恢复 / 软删

    func pauseRule(uuid: UUID) throws {
        let rule = try fetchActiveRule(uuid)
        rule.isPaused = true
        rule.updatedAt = .now
        try context.save()
    }

    /// 恢复：跳过暂停期间错过的各期（暂停即用户明示不要生成），下次触发从 asOf 起重算。
    func resumeRule(uuid: UUID, asOf: Date) throws {
        let rule = try fetchActiveRule(uuid)
        guard let schedule = Schedule(rule: rule) else { throw RecurringRuleServiceError.unsupportedRule }
        rule.isPaused = false
        rule.nextRunAt = try requiredFirstOccurrence(of: schedule, onOrAfter: max(rule.startAt, asOf))
        rule.updatedAt = .now
        try context.save()
    }

    /// 软删即停；已产出流水不动（历史事实，设计文档 §4）。
    func softDeleteRule(uuid: UUID) throws {
        let rule = try fetchActiveRule(uuid)
        rule.isSoftDeleted = true
        rule.updatedAt = .now
        try context.save()
    }

    // MARK: - 到期物化

    /// 到期物化结果：created 为本次生成的流水；skippedRules 为物化失败被跳过的规则
    /// （uuid + 错误描述），供调用方向用户披露——否则坏规则（如引用账户被删）
    /// 会永远静默失败，用户无感知。
    struct MaterializeOutcome {
        struct SkippedRule: Equatable {
            let ruleUUID: UUID
            let message: String
        }

        let created: [Transaction]
        let skippedRules: [SkippedRule]
    }

    /// 把所有到期规则物化为流水并推进 nextRunAt。
    /// 错过多期逐期补记（每期一笔，occurredAt 取各期应发日）；暂停/软删规则不生成。
    /// 幂等：nextRunAt 推进 + 按 (sourceID, occurredAt) 去重双保险，
    /// 重复调用（含崩溃重放）不重复生成；软删的产出也算已生成，不复活。
    @discardableResult
    func materializeDue(asOf: Date) throws -> MaterializeOutcome {
        let dueRules = try context.fetch(
            FetchDescriptor<RecurringRule>(predicate: #Predicate {
                !$0.isSoftDeleted && !$0.isPaused && $0.nextRunAt <= asOf
            })
        )
        var created: [Transaction] = []
        var skipped: [MaterializeOutcome.SkippedRule] = []
        for rule in dueRules {
            // 按规则粒度容错：单条规则物化失败（如引用账户被删、外币无汇率快照）
            // 只跳过该规则（nextRunAt 不推进，下次重试），不炸整批、不吞掉其他规则；
            // 失败规则记入 skippedRules 向调用方披露
            do {
                created += try materialize(rule, asOf: asOf)
            } catch {
                skipped.append(.init(ruleUUID: rule.uuid, message: error.localizedDescription))
            }
        }
        try context.save()
        return MaterializeOutcome(created: created, skippedRules: skipped)
    }

    // MARK: - 私有：单规则物化

    private func materialize(_ rule: RecurringRule, asOf: Date) throws -> [Transaction] {
        // 语义未知（版本偏斜）：跳过不生成也不推进，禁回写兜底（设计文档 §4 前向兼容）
        guard let schedule = Schedule(rule: rule), let kind = rule.templateKind else { return [] }
        // 命令层保证非空，读到 nil 视为脏数据
        guard let ledgerID = rule.templateLedgerID else { throw RecurringRuleServiceError.corruptRule }
        let transactionService = TransactionService(context: context)
        var created: [Transaction] = []
        var due = rule.nextRunAt
        while due <= asOf {
            if let endAt = rule.endAt, due > endAt { break }
            if try !hasExistingOutput(ruleID: rule.uuid, occurredAt: due) {
                // 来源包经参数随 recordTransaction 首个 save 原子落库：崩溃重放时
                // 按 (sourceID, occurredAt) 去重必然命中，不再双记
                let tx = try transactionService.recordTransaction(
                    transactionDraft(from: rule, kind: kind, occurredAt: due), ledgerID: ledgerID,
                    source: (kind: .recurring, id: rule.uuid)
                )
                // 标签挂接在下一次 save 才落盘：崩溃窗口内最坏丢标签，不破坏去重承诺（可接受残余）
                if let tags = try activeTags(rule.templateTagIDs) { tx.tags = tags }
                created.append(tx)
            }
            due = try requiredNextOccurrence(of: schedule, after: due)
        }
        // 无进展不回写（典型：endAt 已过的过期规则，每次都命中谓词、循环立即退出）——
        // 回写 updatedAt 会造成每次调用都产生 CloudKit 同步噪音。不写最安静、语义最简：
        // nextRunAt 停在最后一次推进值，过期规则空转只读不写。
        if rule.nextRunAt != due {
            rule.nextRunAt = due
            rule.updatedAt = .now
        }
        return created
    }

    private func transactionDraft(
        from rule: RecurringRule, kind: TransactionKind, occurredAt: Date
    ) -> TransactionDraft {
        var draft = TransactionDraft()
        draft.kind = kind
        draft.amountString = MoneyAmount.decimalString(fromMinorUnits: rule.templateAmountMinorUnits)
        draft.occurredAt = occurredAt
        draft.note = rule.templateNote
        draft.accountUUID = rule.templateAccountID
        draft.targetAccountUUID = rule.templateTargetAccountID
        draft.categoryUUID = rule.templateCategoryID
        return draft
    }

    /// 该期是否已有产出（含软删——用户删除产出即否决该期，补记不复活）。
    private func hasExistingOutput(ruleID: UUID, occurredAt: Date) throws -> Bool {
        try context.fetchCount(
            FetchDescriptor<Transaction>(predicate: #Predicate {
                $0.sourceID == ruleID && $0.occurredAt == occurredAt
            })
        ) > 0
    }

    /// 解析预设标签（标签量级小，取活跃全集内存过滤即可）；软删标签自然脱落。
    private func activeTags(_ ids: [UUID]) throws -> [Tag]? {
        guard !ids.isEmpty else { return nil }
        let active = try context.fetch(
            FetchDescriptor<Tag>(predicate: #Predicate { !$0.isSoftDeleted })
        )
        let wanted = Set(ids)
        let tags = active.filter { wanted.contains($0.uuid) }
        return tags.isEmpty ? nil : tags
    }

    // MARK: - 私有：触发日计算

    /// 规则的日程参数快照（从校验草稿或落库规则提取）。
    private struct Schedule {
        let frequency: RecurrenceFrequency
        let interval: Int
        let recurrenceDays: [Int]
        let startAt: Date

        init(_ v: RecurringRuleDraft.Validated) {
            frequency = v.frequency
            interval = v.interval
            recurrenceDays = v.recurrenceDays
            startAt = v.startAt
        }

        /// 频率未知（版本偏斜）返回 nil；weekly/monthly 触发日为空时从 startAt 兜底推导。
        init?(rule: RecurringRule) {
            guard let f = rule.frequency, rule.interval >= 1 else { return nil }
            frequency = f
            interval = rule.interval
            startAt = rule.startAt
            if rule.recurrenceDays.isEmpty {
                switch f {
                case .daily: recurrenceDays = []
                case .weekly: recurrenceDays = [Calendar.current.component(.weekday, from: rule.startAt)]
                case .monthly: recurrenceDays = [Calendar.current.component(.day, from: rule.startAt)]
                }
            } else {
                recurrenceDays = rule.recurrenceDays
            }
        }
    }

    private func requiredFirstOccurrence(of schedule: Schedule, onOrAfter lowerBound: Date) throws -> Date {
        guard let occurrence = firstOccurrence(of: schedule, onOrAfter: lowerBound) else {
            throw RecurringRuleServiceError.scheduleComputeFailed
        }
        return occurrence
    }

    private func requiredNextOccurrence(of schedule: Schedule, after due: Date) throws -> Date {
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: due)),
              let occurrence = firstOccurrence(of: schedule, onOrAfter: nextDay) else {
            throw RecurringRuleServiceError.scheduleComputeFailed
        }
        return occurrence
    }

    /// 自 lowerBound（含）起的首个触发时刻。逐日扫描 + 命中判定，正确性优先；
    /// 扫描上限按频率×间隔给足冗余，正常规则必在上限内命中。
    private func firstOccurrence(of schedule: Schedule, onOrAfter lowerBound: Date) -> Date? {
        let bound = max(lowerBound, schedule.startAt)
        var day = calendar.startOfDay(for: bound)
        for _ in 0..<scanCapDays(of: schedule) {
            if matches(schedule, day: day),
               let occurrence = occurrenceTime(onDay: day, of: schedule),
               occurrence >= bound {
                return occurrence
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }

    /// 某自然日是否为触发日（不含时分秒）。
    private func matches(_ schedule: Schedule, day: Date) -> Bool {
        let anchorDay = calendar.startOfDay(for: schedule.startAt)
        switch schedule.frequency {
        case .daily:
            guard let days = calendar.dateComponents([.day], from: anchorDay, to: day).day,
                  days >= 0 else { return false }
            return days % schedule.interval == 0
        case .weekly:
            guard schedule.recurrenceDays.contains(calendar.component(.weekday, from: day)),
                  let anchorWeek = calendar.dateInterval(of: .weekOfYear, for: anchorDay)?.start,
                  let week = calendar.dateInterval(of: .weekOfYear, for: day)?.start,
                  let days = calendar.dateComponents([.day], from: anchorWeek, to: week).day,
                  days >= 0 else { return false }
            return (days / 7) % schedule.interval == 0
        case .monthly:
            let anchor = calendar.dateComponents([.year, .month], from: anchorDay)
            let current = calendar.dateComponents([.year, .month, .day], from: day)
            guard let anchorYear = anchor.year, let anchorMonth = anchor.month,
                  let year = current.year, let month = current.month, let dayOfMonth = current.day,
                  let range = calendar.range(of: .day, in: .month, for: day) else { return false }
            let months = (year - anchorYear) * 12 + (month - anchorMonth)
            guard months >= 0, months % schedule.interval == 0 else { return false }
            // 短月收缩：触发日大于当月天数时取月末（§5.11）；多触发日收缩重合自然只命中一次
            let lastDay = range.count
            return schedule.recurrenceDays.contains { min($0, lastDay) == dayOfMonth }
        }
    }

    /// 触发时刻 = 触发日 + startAt 的时分秒。
    private func occurrenceTime(onDay day: Date, of schedule: Schedule) -> Date? {
        let time = calendar.dateComponents([.hour, .minute, .second], from: schedule.startAt)
        return calendar.date(
            bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: day
        )
    }

    private func scanCapDays(of schedule: Schedule) -> Int {
        switch schedule.frequency {
        case .daily: schedule.interval + 1
        case .weekly: (schedule.interval + 2) * 7
        case .monthly: (schedule.interval + 2) * 31
        }
    }

    // MARK: - 私有：引用校验与查询

    /// 模板引用校验：账本/账户活跃、分类活跃且方向匹配、标签全部存在且活跃。
    private func validateTemplateReferences(_ v: RecurringRuleDraft.Validated) throws {
        try ensureActiveLedger(v.templateLedgerID)
        let account = try ensureActiveAccount(v.templateAccountID)
        if let targetID = v.templateTargetAccountID {
            let target = try ensureActiveAccount(targetID)
            // 跨币种转账模板暂不支持：到账金额每期随汇率浮动，模板无法预先承载（§5.4）
            guard target.currencyCode == account.currencyCode else {
                throw RecurringRuleServiceError.crossCurrencyTransferTemplateUnsupported
            }
        }
        if let categoryID = v.templateCategoryID {
            let descriptor = FetchDescriptor<Category>(
                predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == categoryID }
            )
            guard let category = try context.fetch(descriptor).first else {
                throw RecurringRuleServiceError.categoryNotFound
            }
            guard category.kind == v.templateKind else {
                throw RecurringRuleServiceError.categoryKindMismatch
            }
        }
        if !v.templateTagIDs.isEmpty {
            let found = try activeTags(v.templateTagIDs)?.count ?? 0
            guard found == v.templateTagIDs.count else { throw RecurringRuleServiceError.tagNotFound }
        }
    }

    private func ensureActiveLedger(_ uuid: UUID) throws {
        let count = try context.fetchCount(
            FetchDescriptor<Ledger>(predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid })
        )
        guard count > 0 else { throw RecurringRuleServiceError.ledgerNotFound }
    }

    @discardableResult
    private func ensureActiveAccount(_ uuid: UUID) throws -> Account {
        let descriptor = FetchDescriptor<Account>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        )
        guard let account = try context.fetch(descriptor).first else {
            throw RecurringRuleServiceError.accountNotFound
        }
        return account
    }

    private func fetchActiveRule(_ uuid: UUID) throws -> RecurringRule {
        let descriptor = FetchDescriptor<RecurringRule>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        )
        guard let rule = try context.fetch(descriptor).first else {
            throw RecurringRuleServiceError.ruleNotFound
        }
        return rule
    }

    private func apply(_ v: RecurringRuleDraft.Validated, to rule: RecurringRule) {
        rule.name = v.name
        rule.frequencyRawValue = v.frequency.rawValue
        rule.interval = v.interval
        rule.recurrenceDays = v.recurrenceDays
        rule.startAt = v.startAt
        rule.endAt = v.endAt
        rule.templateKindRawValue = v.templateKind.rawValue
        rule.templateLedgerID = v.templateLedgerID
        rule.templateAmountMinorUnits = v.templateAmountMinorUnits
        rule.templateAccountID = v.templateAccountID
        rule.templateTargetAccountID = v.templateTargetAccountID
        rule.templateCategoryID = v.templateCategoryID
        rule.templateTagIDs = v.templateTagIDs
        rule.templateNote = v.templateNote
    }
}

enum RecurringRuleServiceError: LocalizedError {
    case ruleNotFound
    case ledgerNotFound
    case accountNotFound
    case categoryNotFound
    case categoryKindMismatch
    case tagNotFound
    case noOccurrenceBeforeEnd
    case crossCurrencyTransferTemplateUnsupported
    case unsupportedRule
    case corruptRule
    case scheduleComputeFailed

    var errorDescription: String? {
        switch self {
        case .ruleNotFound: String(localized: "周期计划不存在或已删除")
        case .ledgerNotFound: String(localized: "账本不存在或已删除")
        case .accountNotFound: String(localized: "账户不存在或已删除")
        case .categoryNotFound: String(localized: "分类不存在或已删除")
        case .categoryKindMismatch: String(localized: "分类方向与流水类型不一致")
        case .tagNotFound: String(localized: "标签不存在或已删除")
        case .noOccurrenceBeforeEnd: String(localized: "截止时间之前没有任何触发日")
        case .crossCurrencyTransferTemplateUnsupported: String(localized: "周期计划暂不支持跨币种转账")
        case .unsupportedRule: String(localized: "该周期计划由更高版本创建，请升级 App 后操作")
        case .corruptRule: String(localized: "周期计划数据异常，请删除后重建")
        case .scheduleComputeFailed: String(localized: "无法计算下次触发时间，请检查计划设置")
        }
    }
}
