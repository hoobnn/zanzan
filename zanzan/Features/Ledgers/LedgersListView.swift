import SwiftData
import SwiftUI

/// 账本 Tab 首页（也被「我的 → 账本管理」复用）。静态谓词 @Query；写操作全走 LedgerService。
struct LedgersListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Ledger> { !$0.isSoftDeleted }, sort: \Ledger.sortOrder)
    private var ledgers: [Ledger]

    @State private var isAddingLedger = false
    @State private var editingLedger: Ledger?
    @State private var commandErrorMessage: String?

    var body: some View {
        List {
            ForEach(ledgers) { ledger in
                Button {
                    editingLedger = ledger
                } label: {
                    HStack {
                        Text(ledger.name)
                        Spacer()
                        if ledger.isDefault {
                            Text("默认").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .tint(.primary)
                .swipeActions(edge: .trailing) {
                    Button("删除", systemImage: "trash", role: .destructive) {
                        run { try LedgerService(context: modelContext).softDeleteLedger(uuid: ledger.uuid) }
                    }
                    if !ledger.isDefault {
                        Button("设为默认", systemImage: "checkmark.circle") {
                            run { try LedgerService(context: modelContext).setDefaultLedger(uuid: ledger.uuid) }
                        }
                    }
                }
            }
        }
        .navigationTitle("账本")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("新建账本", systemImage: "plus") { isAddingLedger = true }
            }
        }
        .sheet(isPresented: $isAddingLedger) {
            LedgerFormView(title: String(localized: "新建账本"), draft: LedgerDraft()) { draft in
                try LedgerService(context: modelContext).createLedger(draft)
            }
        }
        .sheet(item: $editingLedger) { ledger in
            LedgerFormView(title: String(localized: "编辑账本"), draft: LedgerDraft(name: ledger.name, colorID: ledger.colorID)) { draft in
                try LedgerService(context: modelContext).updateLedger(uuid: ledger.uuid, draft: draft)
            }
        }
        .alert("操作失败", isPresented: isPresentingError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(commandErrorMessage ?? "")
        }
    }

    private var isPresentingError: Binding<Bool> {
        Binding(
            get: { commandErrorMessage != nil },
            set: { if !$0 { commandErrorMessage = nil } }
        )
    }

    private func run(_ command: () throws -> Void) {
        do { try command() } catch { commandErrorMessage = error.localizedDescription }
    }
}
