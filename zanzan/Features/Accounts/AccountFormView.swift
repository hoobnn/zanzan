import SwiftUI

/// 账户新建/编辑表单；credit 类才展示信用字段（Draft 归一化兜底）。
struct AccountFormView: View {
    let title: String
    @State var draft: AccountDraft
    let onSave: (AccountDraft) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var validationMessage: String?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        AccountIconView(
                            name: draft.name,
                            subtitle: draft.subtitle,
                            kind: draft.kind,
                            size: 52
                        )
                        VStack(alignment: .leading, spacing: 3) {
                            Text(draft.name.isEmpty ? ZanzanLocalization.string("账户图标") : draft.name)
                                .font(.headline)
                            Text("根据银行、渠道或账户名称自动匹配")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    TextField("账户名", text: $draft.name)
                    TextField("副标题（银行/渠道，可选）", text: $draft.subtitle)
                    Picker("类型", selection: $draft.kind) {
                        ForEach(AccountKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .zanzanControlSurface()
                }
                Section("余额") {
                    TextField("币种代码", text: $draft.currencyCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
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
                        .zanzanControlSurface()
                        Picker("还款日", selection: $draft.paymentDueDay) {
                            Text("未设置").tag(Int?.none)
                            ForEach(1...28, id: \.self) { day in
                                Text("\(day) 日").tag(Int?.some(day))
                            }
                        }
                        .zanzanControlSurface()
                    }
                }
                Section {
                    Toggle("计入净资产", isOn: $draft.isIncludedInNetWorth)
                        .zanzanControlSurface()
                    Toggle("可用于记账", isOn: $draft.isSelectableForRecord)
                        .zanzanControlSurface()
                    TextField("备注", text: $draft.note)
                }
                if let validationMessage {
                    Text(validationMessage).font(.footnote).foregroundStyle(.red)
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
        // 防重复提交：dismiss 动画期间连点保存会重复落库；成功关页不复位（页面将销毁）
        guard !isSaving else { return }
        isSaving = true
        do {
            try onSave(draft)
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
            isSaving = false // 失败复位，允许改后重试
        }
    }
}
