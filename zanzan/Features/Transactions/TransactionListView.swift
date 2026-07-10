import SwiftData
import SwiftUI

/// 账本页主体：月份切换 + 月结余卡 + 按日分组流水。
/// 谓词下推命中复合索引（isSoftDeleted, ledgerID, occurredAt），收窄到账本 × 月窗口。
struct TransactionListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var transactions: [StoredTransaction]

    private let ledgerID: UUID
    @Binding private var monthAnchor: Date
    @State private var editingTransaction: StoredTransaction?
    @State private var commandErrorMessage: String?
    @State private var collapsedDays: Set<Date> = []

    init(ledgerID: UUID, monthAnchor: Binding<Date>) {
        self.ledgerID = ledgerID
        _monthAnchor = monthAnchor
        let id: UUID? = ledgerID
        let interval = Calendar.current.dateInterval(of: .month, for: monthAnchor.wrappedValue)
        let monthStart = interval?.start ?? .distantPast
        let monthEnd = interval?.end ?? .distantFuture
        _transactions = Query(
            filter: #Predicate<StoredTransaction> {
                !$0.isSoftDeleted && $0.ledgerID == id
                    && $0.occurredAt >= monthStart && $0.occurredAt < monthEnd
            },
            sort: [SortDescriptor(\StoredTransaction.occurredAt, order: .reverse)]
        )
    }

    private var dayGroups: [(day: Date, items: [StoredTransaction])] {
        Dictionary(grouping: transactions) { Calendar.current.startOfDay(for: $0.occurredAt) }
            .sorted { $0.key > $1.key }
            .map { (day: $0.key, items: $0.value) }
    }

    var body: some View {
        List {
            monthSelectorSection
            Section {
                MonthSummaryCard(
                    expenseMinorUnits: transactions.reduce(0) { $0 + $1.statsExpenseMinorUnits },
                    incomeMinorUnits: transactions.reduce(0) { $0 + $1.statsIncomeMinorUnits }
                )
            }
            if transactions.isEmpty {
                Section {
                    ContentUnavailableView(
                        "本月还没有流水",
                        systemImage: "list.bullet.rectangle",
                        description: Text("点下方「记账」开始记账")
                    )
                    .listRowBackground(Color.clear)
                }
            }
            ForEach(dayGroups, id: \.day) { group in
                daySection(group)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // ponytail: 语音记账入口预留，仅占版式
            Image(systemName: "mic")
                .font(.title3)
                .foregroundStyle(.primary)
                .frame(width: 52, height: 52)
                .background(
                    Circle()
                        .fill(Color(.secondarySystemGroupedBackground))
                        .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
                )
                .padding(.trailing, 20)
                .padding(.bottom, 8)
                .accessibilityHidden(true)
        }
        .fullScreenCover(item: $editingTransaction) { transaction in
            TransactionFormView(ledgerID: ledgerID, editing: transaction)
        }
        .alert("操作失败", isPresented: isPresentingError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(commandErrorMessage ?? "")
        }
    }

    // MARK: - 月份选择行

    private var monthSelectorSection: some View {
        Section {
            HStack(spacing: 12) {
                Text(monthAnchor.formatted(.dateTime.year().month()))
                    .font(.title3.weight(.semibold))
                monthStepButton("chevron.left", label: "上一月") { shiftMonth(-1) }
                monthStepButton("chevron.right", label: "下一月") { shiftMonth(1) }
                Spacer()
                // ponytail: 收支日历入口预留，仅占版式
                Text("收支日历")
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color(.systemGray5)))
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private func monthStepButton(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func shiftMonth(_ delta: Int) {
        guard let shifted = Calendar.current.date(byAdding: .month, value: delta, to: monthAnchor) else { return }
        withAnimation(.snappy) { monthAnchor = shifted }
    }

    // MARK: - 按日分组

    private func daySection(_ group: (day: Date, items: [StoredTransaction])) -> some View {
        Section {
            if !collapsedDays.contains(group.day) {
                ForEach(group.items) { transaction in
                    Button {
                        editingTransaction = transaction
                    } label: {
                        TransactionRowView(transaction: transaction)
                    }
                    .tint(.primary)
                    .swipeActions(edge: .trailing) {
                        Button("删除", systemImage: "trash", role: .destructive) {
                            delete(transaction)
                        }
                    }
                }
            }
        } header: {
            dayHeader(group)
        }
    }

    private func dayHeader(_ group: (day: Date, items: [StoredTransaction])) -> some View {
        Button {
            withAnimation {
                if !collapsedDays.insert(group.day).inserted {
                    collapsedDays.remove(group.day)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(Self.dayFormatter.string(from: group.day))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(daySummary(group.items))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsedDays.contains(group.day) ? -90 : 0))
            }
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .accessibilityHint(collapsedDays.contains(group.day) ? String(localized: "展开当日流水") : String(localized: "折叠当日流水"))
    }

    /// 版式锁定的「07/06 星期一」样式（金额格式同样锁定，见 MoneyFormatter）。
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd EEEE"
        return formatter
    }()

    private func daySummary(_ items: [StoredTransaction]) -> String {
        let expense = items.reduce(0) { $0 + $1.statsExpenseMinorUnits }
        let income = items.reduce(0) { $0 + $1.statsIncomeMinorUnits }
        var parts: [String] = []
        if expense > 0 { parts.append(String(localized: "支出: \(formatAmount(expense))")) }
        if income > 0 { parts.append(String(localized: "收入: \(formatAmount(income))")) }
        return parts.joined(separator: "  ")
    }

    private func delete(_ transaction: StoredTransaction) {
        do {
            try TransactionCommands(context: modelContext).softDeleteTransaction(uuid: transaction.uuid)
        } catch {
            commandErrorMessage = error.localizedDescription
        }
    }

    private var isPresentingError: Binding<Bool> {
        Binding(
            get: { commandErrorMessage != nil },
            set: { if !$0 { commandErrorMessage = nil } }
        )
    }
}
