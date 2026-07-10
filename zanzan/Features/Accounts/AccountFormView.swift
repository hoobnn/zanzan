import SwiftUI

/// 账户新建/编辑表单；credit 类才展示信用字段（Draft 归一化兜底）。
struct AccountFormView: View {
    let title: String
    @State var draft: AccountDraft
    let onSave: (AccountDraft) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("账户名", text: $draft.name)
                    TextField("副标题（银行/渠道，可选）", text: $draft.subtitle)
                    Picker("类型", selection: $draft.kind) {
                        ForEach(AccountKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                }
                Section("余额") {
                    TextField("期初余额", text: $draft.initialBalanceString)
                        .keyboardType(.numbersAndPunctuation) // 需要负号，decimalPad 无
                }
                if draft.kind == .credit {
                    Section("信用") {
                        TextField("信用额度（可选）", text: $draft.creditLimitString)
                            .keyboardType(.decimalPad)
                        Picker("账单日", selection: $draft.statementDay) {
                            Text("未设置").tag(Int?.none)
                            ForEach(1...28, id: \.self) { day in
                                Text("\(day) 日").tag(Int?.some(day))
                            }
                        }
                        Picker("还款日", selection: $draft.paymentDueDay) {
                            Text("未设置").tag(Int?.none)
                            ForEach(1...28, id: \.self) { day in
                                Text("\(day) 日").tag(Int?.some(day))
                            }
                        }
                    }
                }
                Section {
                    Toggle("计入净资产", isOn: $draft.isIncludedInNetWorth)
                    TextField("备注", text: $draft.note)
                }
                if let validationMessage {
                    Text(validationMessage).font(.footnote).foregroundStyle(.red)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
        }
    }

    private func save() {
        do {
            try onSave(draft)
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}
