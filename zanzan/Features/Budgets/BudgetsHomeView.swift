import SwiftData
import SwiftUI

struct BudgetsHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(filter: #Predicate<Ledger> { !$0.isSoftDeleted }, sort: \Ledger.sortOrder)
    private var ledgers: [Ledger]
    @Query(filter: #Predicate<Budget> { !$0.isSoftDeleted })
    private var budgets: [Budget]
    @Query(filter: #Predicate<Transaction> { !$0.isSoftDeleted })
    private var transactions: [Transaction]
    @Query(filter: #Predicate<Category> { !$0.isSoftDeleted })
    private var categories: [Category]

    @State private var selectedLedgerID: UUID?
    @State private var monthAnchor = Date.now
    @State private var isAddingBudget = false
    @State private var editingBudget: Budget?
    @State private var commandErrorMessage: String?
    @State private var budgetPendingDeletion: Budget?

    private var selectedLedger: Ledger? {
        ledgers.first { $0.uuid == selectedLedgerID }
            ?? ledgers.first(where: \.isDefault)
            ?? ledgers.first
    }

    private var progressResult: Result<MonthlyBudgetProgress, Error> {
        _ = budgets.count
        _ = transactions.count
        guard let ledger = selectedLedger else {
            return .failure(BudgetServiceError.ledgerNotFound)
        }
        let components = Calendar.current.dateComponents([.year, .month], from: monthAnchor)
        return Result {
            try BudgetProgressProvider(context: modelContext).progress(
                ledgerID: ledger.uuid,
                year: components.year ?? 0,
                month: components.month ?? 0
            )
        }
    }

    var body: some View {
        List {
            if selectedLedger != nil {
                monthSelector
            }

            switch progressResult {
            case let .success(progress):
                if let total = progress.total {
                    Section("总预算") {
                        progressRow(
                            total,
                            title: ZanzanLocalization.string("本月总预算"),
                            tint: total.usedFraction > 1 ? .zanzanExpense : .zanzanWarm
                        )
                    }
                } else {
                    Section {
                        ContentUnavailableView(
                            "未设置总预算",
                            systemImage: "gauge.with.dots.needle.33percent",
                            description: Text("可以只设置分类预算，也可以添加本月总额度")
                        )
                        .listRowBackground(Color.clear)
                    }
                }

                if !progress.categories.isEmpty {
                    Section("分类预算") {
                        ForEach(progress.categories, id: \.budget.uuid) { item in
                            progressRow(
                                item,
                                title: categoryName(item.budget.categoryID),
                                tint: item.usedFraction > 1 ? .zanzanExpense : .zanzanWarm
                            )
                        }
                    }
                }
            case let .failure(error):
                Section {
                    ContentUnavailableView(
                        "预算读取失败",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error.localizedDescription)
                    )
                    .listRowBackground(Color.clear)
                }
            }
        }
        .accessibilityIdentifier("screen.budgets")
        .zanzanCompactList()
        .zanzanSketchPageBackground()
        .navigationTitle("预算")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ledgerMenu
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Menu("预算操作", systemImage: "ellipsis") {
                    Button("套用默认预算到本月", systemImage: "calendar.badge.plus") {
                        materializeCurrentMonth()
                    }
                    .disabled(selectedLedger?.isArchived != false)
                }
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .primaryAction) {
                Button("添加预算", systemImage: "plus") {
                    isAddingBudget = true
                }
                .buttonStyle(.glassProminent)
                .disabled(selectedLedger?.isArchived != false)
            }
        }
        .sheet(isPresented: $isAddingBudget) {
            if let ledger = selectedLedger, !ledger.isArchived {
                BudgetFormView(
                    title: ZanzanLocalization.string( "添加预算"),
                    ledgerID: ledger.uuid,
                    monthAnchor: monthAnchor
                ) { draft in
                    try BudgetService(context: modelContext).createBudget(draft)
                }
            }
        }
        .sheet(item: $editingBudget) { budget in
            BudgetFormView(
                title: ZanzanLocalization.string( "编辑预算"),
                ledgerID: budget.ledgerID,
                monthAnchor: monthAnchor,
                existingBudget: budget
            ) { draft in
                try BudgetService(context: modelContext)
                    .updateAmount(uuid: budget.uuid, amountMinorUnits: draft.amountMinorUnits)
            }
        }
        .confirmationDialog(
            "删除预算？",
            isPresented: Binding(
                get: { budgetPendingDeletion != nil },
                set: { if !$0 { budgetPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除预算", role: .destructive) {
                guard let budget = budgetPendingDeletion else { return }
                budgetPendingDeletion = nil
                run { try BudgetService(context: modelContext).softDeleteBudget(uuid: budget.uuid) }
            }
            Button("取消", role: .cancel) { budgetPendingDeletion = nil }
        } message: {
            Text("预算会被移入最近删除，不再计入预算进度。")
        }
        .alert("操作失败", isPresented: isPresentingError) { } message: {
            Text(commandErrorMessage ?? "")
        }
    }

    private var monthSelector: some View {
        Section {
            HStack {
                Text(ZanzanLocalization.formatted(monthAnchor, format: .dateTime.year().month()))
                    .font(.headline)
                Spacer()
                Button("上一月", systemImage: "chevron.left") { shiftMonth(-1) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("上一月")
                Button("下一月", systemImage: "chevron.right") { shiftMonth(1) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("下一月")
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private var ledgerMenu: some View {
        Menu {
            ForEach(ledgers) { ledger in
                Button {
                    selectedLedgerID = ledger.uuid
                } label: {
                    if ledger.uuid == selectedLedger?.uuid {
                        Label(ledger.name, systemImage: "checkmark")
                    } else {
                        Text(ledger.name)
                    }
                }
            }
        } label: {
            Label(selectedLedger?.name ?? ZanzanLocalization.string( "选择账本"), systemImage: "books.vertical")
        }
    }

    private func progressRow(_ item: BudgetProgress, title: String, tint: Color) -> some View {
        Button {
            editingBudget = item.budget
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(formatAmount(item.usedMinorUnits)) / \(formatAmount(item.budget.amountMinorUnits))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                ProgressView(value: min(max(item.usedFraction, 0), 1))
                    .tint(tint)
                HStack {
                    Text(item.budget.periodYear == nil ? "默认预算" : "本月预算")
                    Spacer()
                    Text(item.remainingMinorUnits >= 0
                         ? ZanzanLocalization.string( "剩余 \(formatAmount(item.remainingMinorUnits))")
                         : ZanzanLocalization.string( "超支 \(formatAmount(abs(item.remainingMinorUnits)))"))
                }
                .font(.caption)
                .foregroundStyle(item.remainingMinorUnits >= 0 ? .secondary : Color.zanzanExpense)
            }
            .padding(.vertical, 2)
        }
        .swipeActions {
            Button("删除", systemImage: "trash", role: .destructive) {
                budgetPendingDeletion = item.budget
            }
        }
    }

    private func categoryName(_ uuid: UUID?) -> String {
        categories.first { $0.uuid == uuid }?.name ?? ZanzanLocalization.string( "未知分类")
    }

    private func shiftMonth(_ delta: Int) {
        guard let shifted = Calendar.current.date(byAdding: .month, value: delta, to: monthAnchor) else { return }
        if reduceMotion {
            monthAnchor = shifted
        } else {
            withAnimation(.snappy) {
                monthAnchor = shifted
            }
        }
    }

    private func materializeCurrentMonth() {
        guard let ledger = selectedLedger else { return }
        let components = Calendar.current.dateComponents([.year, .month], from: monthAnchor)
        run {
            try BudgetService(context: modelContext).materialize(
                ledgerID: ledger.uuid,
                year: components.year ?? 0,
                month: components.month ?? 0
            )
        }
    }

    private func run(_ command: () throws -> Void) {
        do { try command() } catch { commandErrorMessage = error.localizedDescription }
    }

    private var isPresentingError: Binding<Bool> {
        Binding(
            get: { commandErrorMessage != nil },
            set: { if !$0 { commandErrorMessage = nil } }
        )
    }
}
