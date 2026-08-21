import SwiftData
import SwiftUI

struct CreditCardRepaymentView: View {
    let card: Account

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Account> { !$0.isSoftDeleted && !$0.isArchived && $0.isSelectableForRecord }, sort: \Account.sortOrder)
    private var accounts: [Account]
    @Query(
        filter: #Predicate<Ledger> { !$0.isSoftDeleted && !$0.isArchived },
        sort: \Ledger.sortOrder
    )
    private var ledgers: [Ledger]

    @State private var ledgerID: UUID?
    @State private var sourceAccountID: UUID?
    @State private var amountString = ""
    @State private var targetAmountString = ""
    @State private var feeString = ""
    @State private var occurredAt = Date.now
    @State private var validationMessage: String?
    @State private var isSaving = false

    private var sourceAccounts: [Account] {
        accounts.filter { $0.uuid != card.uuid }
    }

    private var selectedSource: Account? {
        sourceAccounts.first { $0.uuid == sourceAccountID }
    }

    private var isCrossCurrency: Bool {
        selectedSource.map { $0.currencyCode != card.currencyCode } ?? false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("还款信息") {
                    Picker("账本", selection: $ledgerID) {
                        ForEach(ledgers) { ledger in
                            Text(ledger.name).tag(ledger.uuid as UUID?)
                        }
                    }
                    .zanzanControlSurface()
                    Picker("还款账户", selection: $sourceAccountID) {
                        ForEach(sourceAccounts) { account in
                            Text(account.name).tag(account.uuid as UUID?)
                        }
                    }
                    .zanzanControlSurface()
                    LabeledContent("信用卡", value: card.name)
                    TextField("还款金额", text: $amountString)
                        .keyboardType(.decimalPad)
                    if isCrossCurrency {
                        TextField("信用卡到账金额（\(card.currencyCode)）", text: $targetAmountString)
                            .keyboardType(.decimalPad)
                    }
                    TextField("手续费（可选）", text: $feeString)
                        .keyboardType(.decimalPad)
                    DatePicker("还款时间", selection: $occurredAt, in: DraftLimits.occurredAtPickerRange)
                        .zanzanControlSurface()
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
            .navigationTitle("信用卡还款")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                ledgerID = ledgerID ?? ledgers.first(where: \.isDefault)?.uuid ?? ledgers.first?.uuid
                sourceAccountID = sourceAccountID ?? sourceAccounts.first?.uuid
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认还款") { save() }
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
            guard let ledgerID else { throw TransactionServiceError.ledgerNotFound }
            var draft = TransactionDraft()
            draft.kind = .transfer
            draft.amountString = amountString
            draft.targetAmountString = isCrossCurrency ? targetAmountString : ""
            draft.feeString = feeString
            draft.occurredAt = occurredAt
            draft.note = ZanzanLocalization.string( "信用卡还款")
            draft.accountUUID = sourceAccountID
            draft.targetAccountUUID = card.uuid
            try TransactionService(context: modelContext).recordTransaction(draft, ledgerID: ledgerID)
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
            isSaving = false
        }
    }
}
