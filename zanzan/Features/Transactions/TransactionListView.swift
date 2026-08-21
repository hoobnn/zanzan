import SwiftData
import SwiftUI

/// 账本页主体：月份切换 + 月结余卡 + 按日分组流水。
/// 谓词下推命中复合索引（isSoftDeleted, ledgerID, occurredAt），收窄到账本 × 月窗口。
struct TransactionListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var transactions: [Transaction]
    @Query(filter: #Predicate<Account> { !$0.isSoftDeleted }, sort: \Account.sortOrder)
    private var accounts: [Account]
    @Query(filter: #Predicate<Tag> { !$0.isSoftDeleted }, sort: \Tag.sortOrder)
    private var tags: [Tag]

    private let ledgerID: UUID
    @Binding private var monthAnchor: Date
    @State private var editingTransaction: Transaction?
    @State private var commandErrorMessage: String?
    @State private var collapsedDays: Set<Date> = []
    @State private var selectedKind: TransactionKind?
    @State private var selectedAccountID: UUID?
    @State private var selectedTagID: UUID?
    @State private var pendingDeletionID: UUID?

    init(ledgerID: UUID, monthAnchor: Binding<Date>) {
        self.ledgerID = ledgerID
        _monthAnchor = monthAnchor
        let id: UUID? = ledgerID
        let interval = Calendar.current.dateInterval(of: .month, for: monthAnchor.wrappedValue)
        let monthStart = interval?.start ?? .distantPast
        let monthEnd = interval?.end ?? .distantFuture
        _transactions = Query(
            filter: #Predicate<Transaction> {
                !$0.isSoftDeleted && $0.ledgerID == id
                    && $0.occurredAt >= monthStart && $0.occurredAt < monthEnd
            },
            sort: [SortDescriptor(\Transaction.occurredAt, order: .reverse)]
        )
    }

    private var filteredTransactions: [Transaction] {
        transactions.filter { transaction in
            let matchesKind = selectedKind == nil || transaction.kind == selectedKind
            let matchesAccount = selectedAccountID == nil
                || transaction.account?.uuid == selectedAccountID
                || transaction.targetAccount?.uuid == selectedAccountID
            let matchesTag = selectedTagID == nil
                || transaction.tags?.contains { $0.uuid == selectedTagID } == true
            return matchesKind && matchesAccount && matchesTag
        }
    }

    private var groupingResult: Result<[TransactionListGrouping.MonthGroup], Error> {
        Result {
            try TransactionListGrouping.monthGroups(
                of: filteredTransactions,
                context: modelContext
            )
        }
    }

    private var monthGroup: TransactionListGrouping.MonthGroup? {
        try? groupingResult.get().first
    }

    private var groupingError: Error? {
        guard case let .failure(error) = groupingResult else { return nil }
        return error
    }

    private var hasActiveFilter: Bool {
        selectedKind != nil || selectedAccountID != nil || selectedTagID != nil
    }

    var body: some View {
        List {
            monthSelectorSection
            if let groupingError {
                Section {
                    ContentUnavailableView(
                        "流水汇总失败",
                        systemImage: "exclamationmark.triangle",
                        description: Text(groupingError.localizedDescription)
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    MonthSummaryCard(
                        expenseMinorUnits: monthGroup?.expenseTotalMinorUnits ?? 0,
                        incomeMinorUnits: monthGroup?.incomeTotalMinorUnits ?? 0
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                if filteredTransactions.isEmpty {
                    Section {
                        Group {
                            if hasActiveFilter {
                                ContentUnavailableView {
                                    Label("没有匹配的流水", systemImage: "line.3.horizontal.decrease.circle")
                                } description: {
                                    Text("换一个筛选条件，或清除当前筛选")
                                } actions: {
                                    Button("清除筛选") { resetFilters() }
                                        .buttonStyle(.glassProminent)
                                }
                            } else {
                                ContentUnavailableView(
                                    "本月还没有流水",
                                    systemImage: "list.bullet.rectangle",
                                    description: Text("点下方「记账」开始记账")
                                )
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                ForEach(monthGroup?.days ?? [], id: \.day) { group in
                    daySection(group)
                }
            }
        }
        .listSectionSpacing(ZanzanStyle.sketchSectionSpacing)
        .contentMargins(.top, 0, for: .scrollContent)
        .zanzanSketchPageBackground()
        .fullScreenCover(item: $editingTransaction) { transaction in
            TransactionFormView(ledgerID: ledgerID, editing: transaction)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                filterMenu
            }
        }
        .alert("操作失败", isPresented: isPresentingError) { } message: {
            Text(commandErrorMessage ?? "")
        }
    }

    private var filterMenu: some View {
        Menu {
            Section("类型") {
                filterButton(ZanzanLocalization.string("全部类型"), selected: selectedKind == nil) {
                    selectedKind = nil
                }
                ForEach(TransactionKind.allCases, id: \.self) { kind in
                    filterButton(kind.displayName, selected: selectedKind == kind) {
                        selectedKind = kind
                    }
                }
            }

            Section("账户") {
                filterButton(ZanzanLocalization.string("全部账户"), selected: selectedAccountID == nil) {
                    selectedAccountID = nil
                }
                ForEach(accounts) { account in
                    filterButton(account.name, selected: selectedAccountID == account.uuid) {
                        selectedAccountID = account.uuid
                    }
                }
            }

            Section("标签") {
                filterButton(ZanzanLocalization.string("全部标签"), selected: selectedTagID == nil) {
                    selectedTagID = nil
                }
                ForEach(tags.filter { $0.ledgerID == nil || $0.ledgerID == ledgerID }) { tag in
                    filterButton(tag.name, selected: selectedTagID == tag.uuid) {
                        selectedTagID = tag.uuid
                    }
                }
            }

            if hasActiveFilter {
                Button("清除筛选", systemImage: "xmark.circle") {
                    resetFilters()
                }
            }
        } label: {
            Label("筛选", systemImage: hasActiveFilter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
    }

    private func filterButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    // MARK: - 月份选择行

    private var monthSelectorSection: some View {
        Section {
            HStack(spacing: 10) {
                Text(ZanzanLocalization.formatted(monthAnchor, format: .dateTime.year().month()))
                    .font(.title2)
                    .bold()
                Spacer()
                monthStepButton("chevron.left", label: "上一月") { shiftMonth(-1) }
                monthStepButton("chevron.right", label: "下一月") { shiftMonth(1) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .zanzanSketchCard(tint: .zanzanSky)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private func monthStepButton(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .accessibilityLabel(label)
    }

    private func shiftMonth(_ delta: Int) {
        guard let shifted = Calendar.current.date(byAdding: .month, value: delta, to: monthAnchor) else { return }
        performMotionAware {
            monthAnchor = shifted
        }
    }

    // MARK: - 按日分组

    private func daySection(_ group: TransactionListGrouping.DayGroup) -> some View {
        Section {
            if !collapsedDays.contains(group.day) {
                ForEach(group.items) { transaction in
                    Button {
                        editingTransaction = transaction
                    } label: {
                        TransactionRowView(transaction: transaction)
                    }
                    .confirmationDialog(
                        "删除这笔流水？",
                        isPresented: deletionBinding(for: transaction.uuid),
                        titleVisibility: .visible
                    ) {
                        Button("删除流水", role: .destructive) {
                            delete(transaction)
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("删除后，这笔流水将不再计入余额和统计。")
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing) {
                        Button("删除", systemImage: "trash", role: .destructive) {
                            pendingDeletionID = transaction.uuid
                        }
                    }
                }
            }
        } header: {
            dayHeader(group)
        }
    }

    private func dayHeader(_ group: TransactionListGrouping.DayGroup) -> some View {
        Button {
            performMotionAware {
                if !collapsedDays.insert(group.day).inserted {
                    collapsedDays.remove(group.day)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(
                    ZanzanLocalization.formatted(
                        group.day,
                        format: .dateTime.month(.twoDigits).day(.twoDigits).weekday(.wide)
                    )
                )
                    .font(.subheadline)
                    .bold()
                    .foregroundStyle(.secondary)
                Spacer()
                Text(daySummary(group))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsedDays.contains(group.day) ? -90 : 0))
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .accessibilityHint(collapsedDays.contains(group.day) ? ZanzanLocalization.string( "展开当日流水") : ZanzanLocalization.string( "折叠当日流水"))
    }

    private func performMotionAware(_ changes: () -> Void) {
        if reduceMotion {
            changes()
        } else {
            withAnimation(.snappy) {
                changes()
            }
        }
    }

    private func daySummary(_ group: TransactionListGrouping.DayGroup) -> String {
        var parts: [String] = []
        if group.expenseTotalMinorUnits > 0 {
            parts.append(ZanzanLocalization.string( "支出: \(formatAmount(group.expenseTotalMinorUnits))"))
        }
        if group.incomeTotalMinorUnits > 0 {
            parts.append(ZanzanLocalization.string( "收入: \(formatAmount(group.incomeTotalMinorUnits))"))
        }
        return parts.joined(separator: "  ")
    }

    private func resetFilters() {
        selectedKind = nil
        selectedAccountID = nil
        selectedTagID = nil
    }

    private func delete(_ transaction: Transaction) {
        do {
            try TransactionService(context: modelContext).softDeleteTransaction(uuid: transaction.uuid)
        } catch {
            commandErrorMessage = error.localizedDescription
        }
    }

    private func deletionBinding(for uuid: UUID) -> Binding<Bool> {
        Binding(
            get: { pendingDeletionID == uuid },
            set: { if !$0, pendingDeletionID == uuid { pendingDeletionID = nil } }
        )
    }

    private var isPresentingError: Binding<Bool> {
        Binding(
            get: { commandErrorMessage != nil },
            set: { if !$0 { commandErrorMessage = nil } }
        )
    }
}
