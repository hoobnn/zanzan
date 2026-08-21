import SwiftUI

struct CreditPoolFormView: View {
    let title: String
    let onSave: (CreditPoolDraft) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: CreditPoolDraft
    @State private var validationMessage: String?
    @State private var isSaving = false

    init(title: String, draft: CreditPoolDraft, onSave: @escaping (CreditPoolDraft) throws -> Void) {
        self.title = title
        self.onSave = onSave
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("授信池") {
                    TextField("名称", text: $draft.name)
                    TextField("总额度", text: $draft.totalLimitString)
                        .keyboardType(.decimalPad)
                    TextField("币种", text: $draft.currencyCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("备注", text: $draft.note)
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
        guard !isSaving else { return }
        isSaving = true
        do {
            try onSave(draft)
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
            isSaving = false
        }
    }
}
