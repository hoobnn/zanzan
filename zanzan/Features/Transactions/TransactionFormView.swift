import SwiftData
import SwiftUI

/// 记一笔/编辑流水表单。类型 segmented；转账展示双账户 + 手续费；收支展示分类 + 账户。
struct TransactionFormView: View {
    private let ledgerID: UUID
    private let editingUUID: UUID?
    private let isKindLocked: Bool

    @State private var draft: TransactionDraft
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var validationMessage: String?

    @Query(
        filter: #Predicate<StoredAccount> { !$0.isSoftDeleted && !$0.isArchived && $0.isSelectableForRecord },
        sort: \StoredAccount.sortOrder
    )
    private var accounts: [StoredAccount]

    @Query(
        filter: #Predicate<StoredCategory> { !$0.isSoftDeleted && !$0.isArchived },
        sort: \StoredCategory.sortOrder
    )
    private var categories: [StoredCategory]

    init(ledgerID: UUID, editing transaction: StoredTransaction? = nil) {
        self.ledgerID = ledgerID
        self.editingUUID = transaction?.uuid
        self.isKindLocked = transaction != nil
        var draft = TransactionDraft()
        if let transaction {
            draft.kind = transaction.kind ?? .expense
            draft.amountString = MoneyAmount.decimalString(fromMinorUnits: transaction.amountMinorUnits)
            draft.occurredAt = transaction.occurredAt
            draft.note = transaction.note
            draft.accountUUID = transaction.account?.uuid
            draft.targetAccountUUID = transaction.targetAccount?.uuid
            draft.categoryUUID = transaction.category?.uuid
            draft.feeString = transaction.feeMinorUnits == 0
                ? ""
                : MoneyAmount.decimalString(fromMinorUnits: transaction.feeMinorUnits)
        }
        _draft = State(initialValue: draft)
    }

    /// 当前方向可选分类，两级平铺（子类缩进）。父类归档时子类由 kind 过滤后再滤一道。
    private var selectableCategories: [StoredCategory] {
        let directional = categories.filter { $0.kind == draft.kind }
        let parents = directional.filter { $0.parentID == nil }
        return parents.flatMap { parent in
            [parent] + directional.filter { $0.parentID == parent.uuid }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !isKindLocked {
                    Picker("类型", selection: $draft.kind) {
                        ForEach(TransactionKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("金额", text: $draft.amountString)
                        .keyboardType(.decimalPad)
                        .font(.title2)
                }
                if draft.kind == .transfer {
                    Section("转账") {
                        accountPicker("转出账户", selection: $draft.accountUUID)
                        accountPicker("转入账户", selection: $draft.targetAccountUUID)
                        TextField("手续费（可选）", text: $draft.feeString)
                            .keyboardType(.decimalPad)
                    }
                } else {
                    Section {
                        Picker("分类", selection: $draft.categoryUUID) {
                            Text("请选择").tag(UUID?.none)
                            ForEach(selectableCategories) { category in
                                Text(category.parentID == nil ? category.name : "　\(category.name)")
                                    .tag(UUID?.some(category.uuid))
                            }
                        }
                        accountPicker("账户", selection: $draft.accountUUID)
                    }
                }
                Section {
                    DatePicker("日期", selection: $draft.occurredAt)
                    TextField("备注", text: $draft.note)
                }
                if let validationMessage {
                    Text(validationMessage).font(.footnote).foregroundStyle(.red)
                }
            }
            .navigationTitle(editingUUID == nil ? "记一笔" : "编辑流水")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .onChange(of: draft.kind) {
                draft.categoryUUID = nil // 切方向清分类，防方向不匹配
            }
            .onAppear {
                if draft.accountUUID == nil { draft.accountUUID = accounts.first?.uuid }
            }
        }
    }

    private func accountPicker(_ title: String, selection: Binding<UUID?>) -> some View {
        Picker(title, selection: selection) {
            Text("请选择").tag(UUID?.none)
            ForEach(accounts) { account in
                Text(account.name).tag(UUID?.some(account.uuid))
            }
        }
    }

    private func save() {
        do {
            let commands = TransactionCommands(context: modelContext)
            if let editingUUID {
                try commands.updateTransaction(uuid: editingUUID, draft: draft)
            } else {
                try commands.recordTransaction(draft, ledgerID: ledgerID)
            }
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}
