import SwiftData
import SwiftUI

struct RecurringRulesHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<RecurringRule> { !$0.isSoftDeleted }, sort: \RecurringRule.nextRunAt)
    private var rules: [RecurringRule]
    @Query(
        filter: #Predicate<Ledger> { !$0.isSoftDeleted && !$0.isArchived },
        sort: \Ledger.sortOrder
    )
    private var ledgers: [Ledger]
    @Query(filter: #Predicate<Account> { !$0.isSoftDeleted })
    private var accounts: [Account]

    @State private var isAddingRule = false
    @State private var editingRule: RecurringRule?
    @State private var commandMessage: String?
    @State private var commandErrorMessage: String?
    @State private var rulePendingDeletion: RecurringRule?
    @State private var isConfirmingMaterializeDue = false

    var body: some View {
        List {
            ForEach(rules) { rule in
                Button {
                    editingRule = rule
                } label: {
                    HStack(spacing: ZanzanStyle.compactRowSpacing) {
                        Image(systemName: rule.isPaused ? "pause.circle.fill" : "repeat.circle.fill")
                            .foregroundStyle(
                                rule.isPaused
                                    ? AnyShapeStyle(.secondary)
                                    : AnyShapeStyle(.tint)
                            )
                            .frame(
                                width: ZanzanStyle.compactRowIconSize,
                                height: ZanzanStyle.compactRowIconSize
                            )
                            .background {
                                Circle()
                                    .fill(.tint)
                                    .opacity(rule.isPaused ? 0.08 : 0.18)
                            }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name)
                                .foregroundStyle(rule.isPaused ? .secondary : .primary)
                            Text(ruleSubtitle(rule))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(
                            formatAmount(
                                rule.templateAmountMinorUnits,
                                currencyCode: currencyCode(for: rule)
                            )
                        )
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions(edge: .leading) {
                    Button(rule.isPaused ? "恢复" : "暂停", systemImage: rule.isPaused ? "play.fill" : "pause.fill") {
                        run {
                            let service = RecurringRuleService(context: modelContext)
                            if rule.isPaused {
                                try service.resumeRule(uuid: rule.uuid, asOf: .now)
                            } else {
                                try service.pauseRule(uuid: rule.uuid)
                            }
                        }
                    }
                    .tint(rule.isPaused ? Color.primary : .orange)
                }
                .swipeActions(edge: .trailing) {
                    Button("删除", systemImage: "trash", role: .destructive) {
                        rulePendingDeletion = rule
                    }
                }
            }
        }
        .overlay {
            if rules.isEmpty {
                ContentUnavailableView(
                    "还没有周期计划",
                    systemImage: "repeat",
                    description: Text("房租、订阅和工资等固定流水可以自动补记")
                )
            }
        }
        .accessibilityIdentifier("screen.recurring")
        .zanzanCompactList()
        .zanzanSketchPageBackground()
        .navigationTitle("周期记账")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("补记到期流水", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") {
                    isConfirmingMaterializeDue = true
                }
                .confirmationDialog(
                    "补记到期流水",
                    isPresented: $isConfirmingMaterializeDue,
                    titleVisibility: .visible
                ) {
                    Button("补记到期流水") {
                        materializeDue()
                    }
                    Button("取消", role: .cancel) {}
                }
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .primaryAction) {
                Button("新建计划", systemImage: "plus") {
                    isAddingRule = true
                }
                .buttonStyle(.glassProminent)
                .disabled(ledgers.isEmpty)
            }
        }
        .sheet(isPresented: $isAddingRule) {
            if let ledger = ledgers.first(where: \.isDefault) ?? ledgers.first {
                RecurringRuleFormView(
                    title: ZanzanLocalization.string( "新建周期计划"),
                    draft: RecurringRuleDraft(
                        startAt: .now,
                        templateLedgerID: ledger.uuid
                    )
                ) { draft in
                    try RecurringRuleService(context: modelContext).createRule(draft)
                }
            }
        }
        .sheet(item: $editingRule) { rule in
            RecurringRuleFormView(
                title: ZanzanLocalization.string( "编辑周期计划"),
                draft: draft(from: rule)
            ) { draft in
                try RecurringRuleService(context: modelContext)
                    .updateRule(uuid: rule.uuid, draft: draft, asOf: .now)
            }
        }
        .confirmationDialog(
            "删除周期计划？",
            isPresented: Binding(
                get: { rulePendingDeletion != nil },
                set: { if !$0 { rulePendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除计划", role: .destructive) {
                guard let rule = rulePendingDeletion else { return }
                rulePendingDeletion = nil
                run { try RecurringRuleService(context: modelContext).softDeleteRule(uuid: rule.uuid) }
            }
            Button("取消", role: .cancel) { rulePendingDeletion = nil }
        } message: {
            Text("计划会被移入最近删除，不再生成新流水；已生成的流水不受影响。")
        }
        .alert("周期记账", isPresented: isPresentingMessage) { } message: {
            Text(commandMessage ?? "")
        }
        .alert("操作失败", isPresented: isPresentingError) { } message: {
            Text(commandErrorMessage ?? "")
        }
    }

    private func draft(from rule: RecurringRule) -> RecurringRuleDraft {
        var draft = RecurringRuleDraft(
            startAt: rule.startAt,
            templateLedgerID: rule.templateLedgerID ?? ledgers.first?.uuid ?? UUID()
        )
        draft.name = rule.name
        draft.frequency = rule.frequency ?? .monthly
        draft.interval = rule.interval
        draft.recurrenceDays = rule.recurrenceDays
        draft.endAt = rule.endAt
        draft.templateKind = rule.templateKind ?? .expense
        draft.amountString = MoneyAmount.decimalString(fromMinorUnits: rule.templateAmountMinorUnits)
        draft.templateAccountID = rule.templateAccountID
        draft.templateTargetAccountID = rule.templateTargetAccountID
        draft.templateCategoryID = rule.templateCategoryID
        draft.templateTagIDs = rule.templateTagIDs
        draft.templateNote = rule.templateNote
        return draft
    }

    private func currencyCode(for rule: RecurringRule) -> String {
        accounts.first { $0.uuid == rule.templateAccountID }?.currencyCode
            ?? FxConversion.baseCurrencyCode
    }

    private func ruleSubtitle(_ rule: RecurringRule) -> String {
        let frequency = switch rule.frequency {
        case .daily: ZanzanLocalization.string( "每 \(rule.interval) 天")
        case .weekly: ZanzanLocalization.string( "每 \(rule.interval) 周")
        case .monthly: ZanzanLocalization.string( "每 \(rule.interval) 月")
        case nil: ZanzanLocalization.string( "未知频率")
        }
        let next = ZanzanLocalization.formatted(rule.nextRunAt, date: .abbreviated, time: .shortened)
        return rule.isPaused ? ZanzanLocalization.string( "已暂停") : "\(frequency) · \(ZanzanLocalization.string( "下次 \(next)"))"
    }

    private func materializeDue() {
        do {
            let outcome = try RecurringRuleService(context: modelContext).materializeDue(asOf: .now)
            var parts = [ZanzanLocalization.string( "已生成 \(outcome.created.count) 笔流水")]
            if !outcome.skippedRules.isEmpty {
                parts.append(ZanzanLocalization.string( "\(outcome.skippedRules.count) 条规则失败"))
                parts.append(contentsOf: outcome.skippedRules.map(\.message))
            }
            commandMessage = parts.joined(separator: "\n")
        } catch {
            commandErrorMessage = error.localizedDescription
        }
    }

    private func run(_ command: () throws -> Void) {
        do { try command() } catch { commandErrorMessage = error.localizedDescription }
    }

    private var isPresentingMessage: Binding<Bool> {
        Binding(
            get: { commandMessage != nil },
            set: { if !$0 { commandMessage = nil } }
        )
    }

    private var isPresentingError: Binding<Bool> {
        Binding(
            get: { commandErrorMessage != nil },
            set: { if !$0 { commandErrorMessage = nil } }
        )
    }
}
