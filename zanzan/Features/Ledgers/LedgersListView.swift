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
    @State private var pendingDeletionID: UUID?

    var body: some View {
        List {
            ForEach(ledgers) { ledger in
                Button {
                    editingLedger = ledger
                } label: {
                    HStack(spacing: ZanzanStyle.compactRowSpacing) {
                        Image(systemName: "book.closed.fill")
                            .foregroundStyle(
                                ledger.isArchived
                                    ? AnyShapeStyle(.secondary)
                                    : AnyShapeStyle(.tint)
                            )
                            .frame(
                                width: ZanzanStyle.compactRowIconSize,
                                height: ZanzanStyle.compactRowIconSize
                            )
                            .background {
                                RoundedRectangle(cornerRadius: 9)
                                    .fill(.tint)
                                    .opacity(0.18)
                            }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ledger.name)
                            if ledger.isArchived {
                                Text("已归档")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if ledger.isDefault {
                            Text("默认").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .confirmationDialog(
                    "删除这个账本？",
                    isPresented: deletionBinding(for: ledger.uuid),
                    titleVisibility: .visible
                ) {
                    Button("删除账本", role: .destructive) {
                        run { try LedgerService(context: modelContext).softDeleteLedger(uuid: ledger.uuid) }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("关联流水、周期规则或分期计划仍存在时，系统会阻止删除。")
                }
                .swipeActions(edge: .trailing) {
                    Button("删除", systemImage: "trash", role: .destructive) {
                        pendingDeletionID = ledger.uuid
                    }
                    if !ledger.isDefault && !ledger.isArchived {
                        Button("设为默认", systemImage: "checkmark.circle") {
                            run { try LedgerService(context: modelContext).setDefaultLedger(uuid: ledger.uuid) }
                        }
                    }
                }
                .swipeActions(edge: .leading) {
                    if !ledger.isDefault {
                        Button(
                            ledger.isArchived ? "取消归档" : "归档",
                            systemImage: ledger.isArchived ? "tray.and.arrow.up" : "archivebox"
                        ) {
                            run {
                                try LedgerService(context: modelContext).setArchived(
                                    uuid: ledger.uuid,
                                    isArchived: !ledger.isArchived
                                )
                            }
                        }
                        .tint(.orange)
                    }
                }
            }
        }
        .accessibilityIdentifier("screen.ledgers")
        .zanzanCompactList()
        .zanzanSketchPageBackground()
        .navigationTitle("账本")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("新建账本", systemImage: "plus") { isAddingLedger = true }
                    .buttonStyle(.glassProminent)
            }
        }
        .sheet(isPresented: $isAddingLedger) {
            LedgerFormView(title: ZanzanLocalization.string( "新建账本"), draft: LedgerDraft()) { draft in
                try LedgerService(context: modelContext).createLedger(draft)
            }
        }
        .sheet(item: $editingLedger) { ledger in
            LedgerFormView(title: ZanzanLocalization.string( "编辑账本"), draft: LedgerDraft(name: ledger.name, colorID: ledger.colorID)) { draft in
                try LedgerService(context: modelContext).updateLedger(uuid: ledger.uuid, draft: draft)
            }
        }
        .alert("操作失败", isPresented: isPresentingError) { } message: {
            Text(commandErrorMessage ?? "")
        }
    }

    private var isPresentingError: Binding<Bool> {
        Binding(
            get: { commandErrorMessage != nil },
            set: { if !$0 { commandErrorMessage = nil } }
        )
    }

    private func deletionBinding(for uuid: UUID) -> Binding<Bool> {
        Binding(
            get: { pendingDeletionID == uuid },
            set: { if !$0, pendingDeletionID == uuid { pendingDeletionID = nil } }
        )
    }

    private func run(_ command: () throws -> Void) {
        do { try command() } catch { commandErrorMessage = error.localizedDescription }
    }
}
