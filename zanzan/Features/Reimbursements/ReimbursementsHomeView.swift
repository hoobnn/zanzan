import SwiftData
import SwiftUI

struct ReimbursementsHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Transaction> { !$0.isSoftDeleted }, sort: \Transaction.occurredAt, order: .reverse)
    private var transactions: [Transaction]

    @State private var isRecordingSettlement = false
    @State private var commandErrorMessage: String?
    @State private var pendingConfirmation: PendingConfirmation?

    private enum PendingConfirmation: Equatable {
        case settleManually(UUID)
        case unmark(UUID)
        case removeSettlement(UUID)
    }

    private var waiting: [Transaction] {
        transactions.filter { $0.reimbursementStatus == .waiting }
    }

    private var settled: [Transaction] {
        transactions.filter { $0.reimbursementStatus == .settled }
    }

    private var settlementTransactions: [Transaction] {
        transactions.filter { $0.settlementKind != nil }
    }

    var body: some View {
        List {
            Section("待报销") {
                if waiting.isEmpty {
                    Text("没有待报销的垫付")
                        .foregroundStyle(.secondary)
                }
                ForEach(waiting) { transaction in
                    reimbursementRow(transaction)
                        .swipeActions(edge: .leading) {
                            Button("手动结案", systemImage: "checkmark.circle") {
                                pendingConfirmation = .settleManually(transaction.uuid)
                            }
                            .tint(.primary)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("取消标记", systemImage: "xmark.circle", role: .destructive) {
                                pendingConfirmation = .unmark(transaction.uuid)
                            }
                        }
                }
            }

            if !settled.isEmpty {
                Section("已报销") {
                    ForEach(settled) { transaction in
                        reimbursementRow(transaction)
                    }
                }
            }

            if !settlementTransactions.isEmpty {
                Section("到账记录") {
                    ForEach(settlementTransactions) { transaction in
                        TransactionRowView(transaction: transaction)
                            .swipeActions {
                                Button("删除到账", systemImage: "trash", role: .destructive) {
                                    pendingConfirmation = .removeSettlement(transaction.uuid)
                                }
                            }
                    }
                }
            }
        }
        .accessibilityIdentifier("screen.reimbursements")
        .zanzanCompactList()
        .zanzanSketchPageBackground()
        .navigationTitle("报销与退款")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("登记到账", systemImage: "plus") {
                    isRecordingSettlement = true
                }
                .buttonStyle(.glassProminent)
            }
        }
        .sheet(isPresented: $isRecordingSettlement) {
            SettlementFormView()
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            switch pendingConfirmation {
            case let .settleManually(uuid):
                Button("确认结案") {
                    pendingConfirmation = nil
                    run {
                        try ReimbursementService(context: modelContext)
                            .settleManually(transactionUUID: uuid)
                    }
                }
            case let .unmark(uuid):
                Button("取消标记", role: .destructive) {
                    pendingConfirmation = nil
                    run {
                        try ReimbursementService(context: modelContext)
                            .unmarkReimbursement(transactionUUID: uuid)
                    }
                }
            case let .removeSettlement(uuid):
                Button("删除到账记录", role: .destructive) {
                    pendingConfirmation = nil
                    run {
                        try ReimbursementService(context: modelContext)
                            .removeSettlement(transactionUUID: uuid)
                    }
                }
            case nil:
                EmptyView()
            }
            Button("取消", role: .cancel) { pendingConfirmation = nil }
        } message: {
            Text(confirmationMessage)
        }
        .alert("操作失败", isPresented: isPresentingError) { } message: {
            Text(commandErrorMessage ?? "")
        }
    }

    private func reimbursementRow(_ transaction: Transaction) -> some View {
        let allocatedResult = Result {
            try ReimbursementService(context: modelContext)
                .allocatedAmount(originalID: transaction.uuid)
        }

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(transaction.category?.name ?? ZanzanLocalization.string( "未分类"))
                Spacer()
                Text(
                    formatAmount(
                        transaction.amountMinorUnits,
                        currencyCode: transaction.currencyCode
                    )
                )
                    .monospacedDigit()
            }
            switch allocatedResult {
            case let .success(allocated):
                ProgressView(value: Double(allocated), total: Double(max(transaction.amountMinorUnits, 1)))
                    .tint(.zanzanIncome)
                Text(
                    "已到账 \(formatAmount(allocated, currencyCode: transaction.currencyCode)) · \(ZanzanLocalization.formatted(transaction.occurredAt, date: .abbreviated, time: .omitted))"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case let .failure(error):
                Label(
                    "\(ZanzanLocalization.string( "无法读取到账进度"))：\(error.localizedDescription)",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private func run(_ command: () throws -> Void) {
        do { try command() } catch { commandErrorMessage = error.localizedDescription }
    }

    private var confirmationTitle: String {
        switch pendingConfirmation {
        case .settleManually: ZanzanLocalization.string("确认手动结案？")
        case .unmark: ZanzanLocalization.string("取消报销标记？")
        case .removeSettlement: ZanzanLocalization.string("删除到账记录？")
        case nil: ""
        }
    }

    private var confirmationMessage: String {
        switch pendingConfirmation {
        case .settleManually: ZanzanLocalization.string("结案后这笔垫付会直接标记为已报销。")
        case .unmark: ZanzanLocalization.string("取消后，这笔支出将不再出现在待报销列表中。")
        case .removeSettlement: ZanzanLocalization.string("关联的报销或退款进度会同步回退。")
        case nil: ""
        }
    }

    private var isPresentingError: Binding<Bool> {
        Binding(
            get: { commandErrorMessage != nil },
            set: { if !$0 { commandErrorMessage = nil } }
        )
    }
}
