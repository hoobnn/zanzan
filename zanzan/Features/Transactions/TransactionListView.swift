import SwiftData
import SwiftUI

/// 账本内流水列表：谓词下推命中复合索引（isSoftDeleted, ledgerID, occurredAt），按天分组。
/// 内嵌子视图经 init 参数化谓词（非 navigationDestination 目标页，不触历史教训红线）。
struct TransactionListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var transactions: [StoredTransaction]

    private let ledgerID: UUID
    @State private var isRecording = false
    @State private var editingTransaction: StoredTransaction?
    @State private var commandErrorMessage: String?

    init(ledgerID: UUID) {
        self.ledgerID = ledgerID
        let id: UUID? = ledgerID
        _transactions = Query(
            filter: #Predicate<StoredTransaction> { !$0.isSoftDeleted && $0.ledgerID == id },
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
            ForEach(dayGroups, id: \.day) { group in
                Section {
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
                } header: {
                    Text(group.day, format: .dateTime.month().day().weekday())
                }
            }
        }
        .overlay {
            if transactions.isEmpty {
                ContentUnavailableView(
                    "还没有流水",
                    systemImage: "list.bullet.rectangle",
                    description: Text("点右上角「记一笔」开始记账")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("记一笔", systemImage: "plus") { isRecording = true }
            }
        }
        .sheet(isPresented: $isRecording) {
            TransactionFormView(ledgerID: ledgerID)
        }
        .sheet(item: $editingTransaction) { transaction in
            TransactionFormView(ledgerID: ledgerID, editing: transaction)
        }
        .alert("操作失败", isPresented: isPresentingError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(commandErrorMessage ?? "")
        }
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

// TODO(Task 10): 占位，记一笔表单在下一任务实现
struct TransactionFormView: View {
    let ledgerID: UUID
    var editing: StoredTransaction? = nil
    var body: some View { EmptyView() }
}
