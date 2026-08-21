import SwiftData
import SwiftUI

struct TagFormView: View {
    let title: String
    let editingUUID: UUID?
    let onSave: (TagDraft) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(
        filter: #Predicate<Ledger> { !$0.isSoftDeleted && !$0.isArchived },
        sort: \Ledger.sortOrder
    )
    private var ledgers: [Ledger]

    @State private var draft: TagDraft
    @State private var validationMessage: String?
    @State private var isSaving = false

    private let colorIDs = ["blue", "green", "orange", "red", "purple", "pink", "teal", "gray"]

    init(
        title: String,
        draft: TagDraft,
        editingUUID: UUID? = nil,
        onSave: @escaping (TagDraft) throws -> Void
    ) {
        self.title = title
        self.editingUUID = editingUUID
        self.onSave = onSave
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("标签") {
                    TextField("标签名称", text: $draft.name)
                    Picker("颜色", selection: $draft.colorID) {
                        ForEach(colorIDs, id: \.self) { colorID in
                            Label {
                                Text(colorName(colorID))
                            } icon: {
                                Image(systemName: "circle.fill")
                                    .foregroundStyle(Color.zanzan(token: colorID))
                            }
                            .tag(colorID)
                        }
                    }
                    .zanzanControlSurface()
                }

                Section("使用范围") {
                    Picker("归属", selection: $draft.ledgerID) {
                        Text("全部账本").tag(nil as UUID?)
                        ForEach(ledgers) { ledger in
                            Text(ledger.name).tag(ledger.uuid as UUID?)
                        }
                    }
                    .zanzanControlSurface()
                    .disabled(editingUUID != nil)
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

    private func colorName(_ colorID: String) -> String {
        switch colorID {
        case "blue": ZanzanLocalization.string("蓝色")
        case "green": ZanzanLocalization.string("绿色")
        case "orange": ZanzanLocalization.string("橙色")
        case "red": ZanzanLocalization.string("红色")
        case "purple": ZanzanLocalization.string("紫色")
        case "pink": ZanzanLocalization.string("粉色")
        case "teal": ZanzanLocalization.string("青色")
        default: ZanzanLocalization.string("灰色")
        }
    }
}
