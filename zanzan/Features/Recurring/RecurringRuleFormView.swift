import SwiftData
import SwiftUI

struct RecurringRuleFormView: View {
    let title: String
    let onSave: (RecurringRuleDraft) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(
        filter: #Predicate<Ledger> { !$0.isSoftDeleted && !$0.isArchived },
        sort: \Ledger.sortOrder
    )
    private var ledgers: [Ledger]
    @Query(filter: #Predicate<Account> { !$0.isSoftDeleted && !$0.isArchived && $0.isSelectableForRecord }, sort: \Account.sortOrder)
    private var accounts: [Account]
    @Query(filter: #Predicate<Category> { !$0.isSoftDeleted && !$0.isArchived }, sort: \Category.sortOrder)
    private var categories: [Category]
    @Query(filter: #Predicate<Tag> { !$0.isSoftDeleted && !$0.isArchived }, sort: \Tag.sortOrder)
    private var tags: [Tag]

    @State private var draft: RecurringRuleDraft
    @State private var hasEndDate: Bool
    @State private var validationMessage: String?
    @State private var isSaving = false

    init(
        title: String,
        draft: RecurringRuleDraft,
        onSave: @escaping (RecurringRuleDraft) throws -> Void
    ) {
        self.title = title
        self.onSave = onSave
        _draft = State(initialValue: draft)
        _hasEndDate = State(initialValue: draft.endAt != nil)
    }

    private var selectableCategories: [Category] {
        categories.filter {
            $0.kind == draft.templateKind
                && ($0.ledgerID == nil || $0.ledgerID == draft.templateLedgerID)
        }
    }

    private var selectableTags: [Tag] {
        tags.filter { $0.ledgerID == nil || $0.ledgerID == draft.templateLedgerID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("计划") {
                    TextField("计划名称", text: $draft.name)
                    Picker("频率", selection: $draft.frequency) {
                        Text("每天").tag(RecurrenceFrequency.daily)
                        Text("每周").tag(RecurrenceFrequency.weekly)
                        Text("每月").tag(RecurrenceFrequency.monthly)
                    }
                    .zanzanControlSurface()
                    Stepper("每 \(draft.interval) 个周期", value: $draft.interval, in: 1...DraftLimits.maxRecurrenceInterval)
                        .zanzanControlSurface()
                    DatePicker("开始时间", selection: $draft.startAt, in: DraftLimits.occurredAtPickerRange)
                        .zanzanControlSurface()
                    Toggle("设置截止时间", isOn: $hasEndDate)
                        .zanzanControlSurface()
                    if hasEndDate {
                        DatePicker(
                            "截止时间",
                            selection: Binding(
                                get: { draft.endAt ?? draft.startAt },
                                set: { draft.endAt = $0 }
                            ),
                            in: draft.startAt...DraftLimits.occurredAtRange.upperBound
                        )
                        .zanzanControlSurface()
                    }
                }

                Section("流水模板") {
                    Picker("类型", selection: $draft.templateKind) {
                        ForEach(TransactionKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .zanzanControlSurface()
                    .onChange(of: draft.templateKind) {
                        draft.templateCategoryID = nil
                        draft.templateTargetAccountID = nil
                    }
                    Picker("账本", selection: $draft.templateLedgerID) {
                        ForEach(ledgers) { ledger in
                            Text(ledger.name).tag(ledger.uuid)
                        }
                    }
                    .zanzanControlSurface()
                    .onChange(of: draft.templateLedgerID) {
                        draft.templateCategoryID = nil
                        draft.templateTagIDs.removeAll()
                    }
                    Picker(draft.templateKind == .transfer ? "转出账户" : "账户", selection: $draft.templateAccountID) {
                        ForEach(accounts) { account in
                            Text(account.name).tag(account.uuid as UUID?)
                        }
                    }
                    .zanzanControlSurface()
                    if draft.templateKind == .transfer {
                        Picker("转入账户", selection: $draft.templateTargetAccountID) {
                            ForEach(accounts) { account in
                                Text(account.name).tag(account.uuid as UUID?)
                            }
                        }
                        .zanzanControlSurface()
                    } else {
                        Picker("分类", selection: $draft.templateCategoryID) {
                            ForEach(selectableCategories) { category in
                                Text(category.name).tag(category.uuid as UUID?)
                            }
                        }
                        .zanzanControlSurface()
                    }
                    TextField("金额", text: $draft.amountString)
                        .keyboardType(.decimalPad)
                    TextField("备注（可选）", text: $draft.templateNote)
                }

                Section("标签") {
                    if selectableTags.isEmpty {
                        Text("暂无可用标签")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(selectableTags) { tag in
                        Button {
                            if let index = draft.templateTagIDs.firstIndex(of: tag.uuid) {
                                draft.templateTagIDs.remove(at: index)
                            } else {
                                draft.templateTagIDs.append(tag.uuid)
                            }
                        } label: {
                            HStack {
                                Label(tag.name, systemImage: "tag.fill")
                                Spacer()
                                if draft.templateTagIDs.contains(tag.uuid) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .zanzanControlSurface()
                        .accessibilityAddTraits(
                            draft.templateTagIDs.contains(tag.uuid) ? .isSelected : []
                        )
                        .accessibilityValue(
                            draft.templateTagIDs.contains(tag.uuid) ? "已选择" : "未选择"
                        )
                    }
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .textFieldStyle(.zanzan)
            .zanzanCompactList()
            .zanzanSketchPageBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: hasEndDate) {
                draft.endAt = hasEndDate ? (draft.endAt ?? draft.startAt) : nil
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .buttonStyle(.glassProminent)
                        .disabled(isSaving)
                }
            }
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        do {
            try onSave(draft)
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
            isSaving = false
        }
    }
}
