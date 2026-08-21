import SwiftUI

/// 账本新建/编辑表单；Draft 校验错误内联展示（三层防线第一层落 UI）。
struct LedgerFormView: View {
    let title: String
    @State var draft: LedgerDraft
    let onSave: (LedgerDraft) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var validationMessage: String?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("账本名", text: $draft.name)
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
