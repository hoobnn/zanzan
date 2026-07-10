import SwiftUI

/// 账本新建/编辑表单；Draft 校验错误内联展示（三层防线第一层落 UI）。
struct LedgerFormView: View {
    let title: String
    @State var draft: LedgerDraft
    let onSave: (LedgerDraft) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("账本名", text: $draft.name)
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
