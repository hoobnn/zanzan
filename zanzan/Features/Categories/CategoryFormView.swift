import SwiftData
import SwiftUI

struct CategoryFormView: View {
    let title: String
    let editingUUID: UUID?
    let onSave: (CategoryDraft) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Category> { !$0.isSoftDeleted }, sort: \Category.sortOrder)
    private var categories: [Category]
    @Query(
        filter: #Predicate<Ledger> { !$0.isSoftDeleted && !$0.isArchived },
        sort: \Ledger.sortOrder
    )
    private var ledgers: [Ledger]

    @State private var draft: CategoryDraft
    @State private var validationMessage: String?
    @State private var isSaving = false

    init(
        title: String,
        draft: CategoryDraft,
        editingUUID: UUID? = nil,
        onSave: @escaping (CategoryDraft) throws -> Void
    ) {
        self.title = title
        self.editingUUID = editingUUID
        self.onSave = onSave
        _draft = State(initialValue: draft)
    }

    private var parentCategories: [Category] {
        categories.filter {
            $0.uuid != editingUUID
                && $0.parentID == nil
                && $0.kind == draft.kind
                && $0.ledgerID == draft.ledgerID
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    HStack(spacing: 12) {
                        CategoryIconView(
                            symbol: draft.iconPrimary.isEmpty ? "tag" : draft.iconPrimary,
                            size: 44
                        )
                        Text("预置分类会自动使用对应的彩色图标")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TextField("分类名称", text: $draft.name)
                    Picker("收支类型", selection: $draft.kind) {
                        Text(TransactionKind.expense.displayName).tag(TransactionKind.expense)
                        Text(TransactionKind.income.displayName).tag(TransactionKind.income)
                    }
                    .zanzanControlSurface()
                    .disabled(editingUUID != nil)

                    Picker("适用账本", selection: $draft.ledgerID) {
                        Text("全部账本").tag(UUID?.none)
                        ForEach(ledgers) { ledger in
                            Text(ledger.name).tag(ledger.uuid as UUID?)
                        }
                    }
                    .zanzanControlSurface()
                    .disabled(editingUUID != nil)
                    .onChange(of: draft.ledgerID) {
                        draft.parentID = nil
                    }

                    TextField("SF Symbol 图标", text: $draft.iconPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Picker("父分类", selection: $draft.parentID) {
                        Text("一级分类").tag(nil as UUID?)
                        ForEach(parentCategories) { category in
                            Text(category.name).tag(category.uuid as UUID?)
                        }
                    }
                    .zanzanControlSurface()
                } header: {
                    Text("层级")
                } footer: {
                    Text("分类最多支持两级；归档只影响后续记账，历史统计仍会保留。")
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
