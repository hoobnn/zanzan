import SwiftData
import SwiftUI

struct BudgetFormView: View {
    let title: String
    let ledgerID: UUID
    let monthAnchor: Date
    let existingBudget: Budget?
    let onSave: (BudgetDraft) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(
        filter: #Predicate<Category> {
            !$0.isSoftDeleted && !$0.isArchived && $0.parentID == nil
                && $0.kindRawValue == "expense"
        },
        sort: \Category.sortOrder
    )
    private var categories: [Category]

    @State private var categoryID: UUID?
    @State private var amountString: String
    @State private var isMonthly: Bool
    @State private var validationMessage: String?
    @State private var isSaving = false

    private var selectableCategories: [Category] {
        categories.filter { $0.ledgerID == nil || $0.ledgerID == ledgerID }
    }

    init(
        title: String,
        ledgerID: UUID,
        monthAnchor: Date,
        existingBudget: Budget? = nil,
        onSave: @escaping (BudgetDraft) throws -> Void
    ) {
        self.title = title
        self.ledgerID = ledgerID
        self.monthAnchor = monthAnchor
        self.existingBudget = existingBudget
        self.onSave = onSave
        _categoryID = State(initialValue: existingBudget?.categoryID)
        _amountString = State(initialValue: existingBudget.map {
            MoneyAmount.decimalString(fromMinorUnits: $0.amountMinorUnits)
        } ?? "")
        _isMonthly = State(initialValue: existingBudget?.periodYear != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("预算对象") {
                    Picker("分类", selection: $categoryID) {
                        Text("总预算").tag(nil as UUID?)
                        ForEach(selectableCategories) { category in
                            Text(category.name).tag(category.uuid as UUID?)
                        }
                    }
                    .zanzanControlSurface()
                    .disabled(existingBudget != nil)

                    Toggle("仅本月生效", isOn: $isMonthly)
                        .zanzanControlSurface()
                        .disabled(existingBudget != nil)
                }

                Section {
                    TextField("预算金额", text: $amountString)
                        .keyboardType(.decimalPad)
                } header: {
                    Text("额度")
                } footer: {
                    Text(isMonthly ? "本月预算会覆盖同分类的默认预算。" : "默认预算会自动用于未来月份，历史月份不受后续修改影响。")
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
        let components = Calendar.current.dateComponents([.year, .month], from: monthAnchor)
        do {
            guard let amount = MoneyAmount.minorUnits(fromDecimalString: amountString) else {
                throw BudgetDraftError.nonPositiveAmount
            }
            let draft = BudgetDraft(
                ledgerID: ledgerID,
                categoryID: categoryID,
                periodYear: isMonthly ? components.year : nil,
                periodMonth: isMonthly ? components.month : nil,
                amountMinorUnits: amount
            )
            try onSave(draft)
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
            isSaving = false
        }
    }
}
