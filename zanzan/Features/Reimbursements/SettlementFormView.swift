import SwiftData
import SwiftUI

struct SettlementFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(
        filter: #Predicate<Ledger> { !$0.isSoftDeleted && !$0.isArchived },
        sort: \Ledger.sortOrder
    )
    private var ledgers: [Ledger]
    @Query(filter: #Predicate<Account> { !$0.isSoftDeleted && !$0.isArchived && $0.isSelectableForRecord }, sort: \Account.sortOrder)
    private var accounts: [Account]
    @Query(filter: #Predicate<Transaction> { !$0.isSoftDeleted }, sort: \Transaction.occurredAt, order: .reverse)
    private var transactions: [Transaction]

    @State private var kind = TransactionLinkKind.reimbursement
    @State private var ledgerID: UUID?
    @State private var accountID: UUID?
    @State private var settlementAmountString = ""
    @State private var selectedOriginalIDs: Set<UUID> = []
    @State private var allocationStrings: [UUID: String] = [:]
    @State private var occurredAt = Date.now
    @State private var note = ""
    @State private var validationMessage: String?
    @State private var isSaving = false

    private var originalCandidates: [(transaction: Transaction, remaining: Result<Int, Error>)] {
        transactions.compactMap { transaction in
            guard transaction.kind == .expense,
                  transaction.ledgerID == ledgerID,
                  kind == .refund || transaction.reimbursementStatus != nil else {
                return nil
            }
            let remaining = Result { try remainingAmount(of: transaction) }
            if case let .success(amount) = remaining, amount <= 0 {
                return nil
            }
            return (transaction, remaining)
        }
    }

    var body: some View {
        let candidates = originalCandidates
        return NavigationStack {
            Form {
                Section {
                    Picker("到账类型", selection: $kind) {
                        Text("报销打款").tag(TransactionLinkKind.reimbursement)
                        Text("退款到账").tag(TransactionLinkKind.refund)
                    }
                    .pickerStyle(.segmented)
                    .zanzanControlSurface()
                    .onChange(of: kind) { resetOriginals() }

                    Picker("账本", selection: $ledgerID) {
                        ForEach(ledgers) { ledger in
                            Text(ledger.name).tag(ledger.uuid as UUID?)
                        }
                    }
                    .zanzanControlSurface()
                    .onChange(of: ledgerID) { resetOriginals() }
                    Picker("到账账户", selection: $accountID) {
                        ForEach(accounts) { account in
                            Text(account.name).tag(account.uuid as UUID?)
                        }
                    }
                    .zanzanControlSurface()
                    TextField("实际到账金额", text: $settlementAmountString)
                        .keyboardType(.decimalPad)
                    DatePicker("到账时间", selection: $occurredAt, in: DraftLimits.occurredAtPickerRange)
                        .zanzanControlSurface()
                    TextField("备注（可选）", text: $note)
                }

                Section("关联原支出") {
                    if candidates.isEmpty {
                        Text(kind == .reimbursement ? "本账本没有待关联的垫付支出" : "本账本没有可关联的支出")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(candidates, id: \.transaction.uuid) { candidate in
                        switch candidate.remaining {
                        case let .success(remaining):
                            VStack(alignment: .leading, spacing: 8) {
                                Button {
                                    toggle(candidate.transaction, remainingAmount: remaining)
                                } label: {
                                    HStack {
                                        Image(
                                            systemName: selectedOriginalIDs.contains(candidate.transaction.uuid)
                                                ? "checkmark.circle.fill"
                                                : "circle"
                                        )
                                        .foregroundStyle(
                                            selectedOriginalIDs.contains(candidate.transaction.uuid)
                                                ? Color.primary
                                                : .secondary
                                        )
                                        .accessibilityHidden(true)
                                        VStack(alignment: .leading) {
                                            Text(
                                                candidate.transaction.category?.name
                                                    ?? ZanzanLocalization.string( "未分类")
                                            )
                                            Text(
                                                "\(ZanzanLocalization.formatted(candidate.transaction.occurredAt, date: .abbreviated, time: .omitted)) · 可分摊 \(formatAmount(remaining, currencyCode: candidate.transaction.currencyCode))"
                                            )
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(.rect)
                                .buttonStyle(.plain)
                                .zanzanControlSurface()
                                .accessibilityAddTraits(
                                    selectedOriginalIDs.contains(candidate.transaction.uuid)
                                        ? .isSelected
                                        : []
                                )
                                .accessibilityValue(
                                    selectedOriginalIDs.contains(candidate.transaction.uuid)
                                        ? "已选择"
                                        : "未选择"
                                )
                                .accessibilityLabel(
                                    selectedOriginalIDs.contains(candidate.transaction.uuid)
                                        ? Text(
                                            "取消选择 \(candidate.transaction.category?.name ?? ZanzanLocalization.string( "未分类"))"
                                        )
                                        : Text(
                                            "选择 \(candidate.transaction.category?.name ?? ZanzanLocalization.string( "未分类"))"
                                        )
                                )

                                if selectedOriginalIDs.contains(candidate.transaction.uuid) {
                                    TextField(
                                        "本次分摊金额",
                                        text: allocationBinding(for: candidate.transaction.uuid)
                                    )
                                    .keyboardType(.decimalPad)
                                }
                            }
                        case let .failure(error):
                            Label {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("无法读取可分摊金额")
                                    Text(error.localizedDescription)
                                        .font(.caption)
                                }
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                            }
                            .foregroundStyle(.red)
                            .accessibilityElement(children: .combine)
                        }
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
            .navigationTitle("登记到账")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                ledgerID = ledgerID ?? ledgers.first(where: \.isDefault)?.uuid ?? ledgers.first?.uuid
                accountID = accountID ?? accounts.first?.uuid
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .buttonStyle(.glassProminent)
                        .tint(.zanzanIncome)
                        .disabled(isSaving || ledgerID == nil || accountID == nil)
                }
            }
        }
    }

    private func remainingAmount(of transaction: Transaction) throws -> Int {
        let allocated = try ReimbursementService(context: modelContext)
            .allocatedAmount(originalID: transaction.uuid)
        return max(0, transaction.amountMinorUnits - allocated)
    }

    private func toggle(_ transaction: Transaction, remainingAmount: Int) {
        if !selectedOriginalIDs.insert(transaction.uuid).inserted {
            selectedOriginalIDs.remove(transaction.uuid)
            allocationStrings[transaction.uuid] = nil
        } else {
            allocationStrings[transaction.uuid] = MoneyAmount.decimalString(
                fromMinorUnits: remainingAmount
            )
        }
        if kind == .refund {
            do {
                let total = try MoneyArithmetic.sum(
                    selectedOriginalIDs
                        .compactMap { allocationStrings[$0] }
                        .compactMap(MoneyAmount.minorUnits(fromDecimalString:))
                )
                settlementAmountString = MoneyAmount.decimalString(fromMinorUnits: total)
            } catch {
                validationMessage = error.localizedDescription
            }
        }
    }

    private func allocationBinding(for uuid: UUID) -> Binding<String> {
        Binding(
            get: { allocationStrings[uuid] ?? "" },
            set: { allocationStrings[uuid] = $0 }
        )
    }

    private func resetOriginals() {
        selectedOriginalIDs.removeAll()
        allocationStrings.removeAll()
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        do {
            guard let ledgerID else { throw ReimbursementServiceError.ledgerNotFound }
            guard let accountID else { throw ReimbursementServiceError.accountNotFound }
            guard let amount = MoneyAmount.minorUnits(fromDecimalString: settlementAmountString) else {
                throw ReimbursementServiceError.invalidSettlementAmount
            }
            let allocations = try selectedOriginalIDs.map { uuid in
                guard let string = allocationStrings[uuid],
                      let amount = MoneyAmount.minorUnits(fromDecimalString: string) else {
                    throw ReimbursementServiceError.invalidAllocation
                }
                return ReimbursementService.Allocation(
                    originalTransactionUUID: uuid,
                    amountMinorUnits: amount
                )
            }
            try ReimbursementService(context: modelContext).recordSettlement(
                kind: kind,
                amountMinorUnits: amount,
                occurredAt: occurredAt,
                accountUUID: accountID,
                ledgerID: ledgerID,
                note: note,
                allocations: allocations
            )
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
            isSaving = false
        }
    }
}
