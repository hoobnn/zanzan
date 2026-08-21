import SwiftData
import SwiftUI

struct TagsHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Tag> { !$0.isSoftDeleted }, sort: \Tag.sortOrder)
    private var tags: [Tag]
    @Query(filter: #Predicate<Ledger> { !$0.isSoftDeleted }, sort: \Ledger.sortOrder)
    private var ledgers: [Ledger]

    @State private var isAddingTag = false
    @State private var editingTag: Tag?
    @State private var commandErrorMessage: String?
    @State private var tagPendingDeletion: Tag?

    var body: some View {
        List {
            tagSection(
                ZanzanLocalization.string("全部账本"),
                tags: tags.filter { $0.ledgerID == nil }
            )
            ForEach(ledgers) { ledger in
                tagSection(ledger.name, tags: tags.filter { $0.ledgerID == ledger.uuid })
            }
        }
        .overlay {
            if tags.isEmpty {
                ContentUnavailableView(
                    "还没有标签",
                    systemImage: "tag",
                    description: Text("标签可用于多账本整理和筛选流水")
                )
            }
        }
        .accessibilityIdentifier("screen.tags")
        .zanzanCompactList()
        .zanzanSketchPageBackground()
        .navigationTitle("标签管理")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("新建标签", systemImage: "plus") {
                    isAddingTag = true
                }
                .buttonStyle(.glassProminent)
            }
        }
        .sheet(isPresented: $isAddingTag) {
            TagFormView(title: ZanzanLocalization.string( "新建标签"), draft: TagDraft()) { draft in
                try TagService(context: modelContext).createTag(draft)
            }
        }
        .sheet(item: $editingTag) { tag in
            TagFormView(
                title: ZanzanLocalization.string( "编辑标签"),
                draft: TagDraft(tag: tag),
                editingUUID: tag.uuid
            ) { draft in
                try TagService(context: modelContext).updateTag(uuid: tag.uuid, draft: draft)
            }
        }
        .confirmationDialog(
            "删除标签？",
            isPresented: Binding(
                get: { tagPendingDeletion != nil },
                set: { if !$0 { tagPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除标签", role: .destructive) {
                guard let tag = tagPendingDeletion else { return }
                tagPendingDeletion = nil
                run { try TagService(context: modelContext).softDeleteTag(uuid: tag.uuid) }
            }
            Button("取消", role: .cancel) { tagPendingDeletion = nil }
        } message: {
            Text("标签会被移入最近删除；历史流水不会被删除。")
        }
        .alert("操作失败", isPresented: isPresentingError) { } message: {
            Text(commandErrorMessage ?? "")
        }
    }

    @ViewBuilder
    private func tagSection(_ title: String, tags: [Tag]) -> some View {
        if !tags.isEmpty {
            Section(title) {
                ForEach(tags) { tag in
                    Button {
                        editingTag = tag
                    } label: {
                        HStack(spacing: ZanzanStyle.compactRowSpacing) {
                            Image(systemName: "tag.fill")
                                .foregroundStyle(Color.zanzan(token: tag.colorID))
                                .frame(
                                    width: ZanzanStyle.compactRowIconSize,
                                    height: ZanzanStyle.compactRowIconSize
                                )
                                .background(Color.zanzan(token: tag.colorID).opacity(0.14), in: .circle)
                            Text(tag.name)
                                .foregroundStyle(tag.isArchived ? .secondary : .primary)
                            Spacer()
                            if tag.isArchived {
                                Text("已归档")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button(tag.isArchived ? "取消归档" : "归档", systemImage: tag.isArchived ? "tray.and.arrow.up" : "archivebox") {
                            run {
                                try TagService(context: modelContext)
                                    .setArchived(uuid: tag.uuid, isArchived: !tag.isArchived)
                            }
                        }
                        .tint(.orange)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("删除", systemImage: "trash", role: .destructive) {
                            tagPendingDeletion = tag
                        }
                    }
                }
            }
        }
    }

    private func run(_ command: () throws -> Void) {
        do { try command() } catch { commandErrorMessage = error.localizedDescription }
    }

    private var isPresentingError: Binding<Bool> {
        Binding(
            get: { commandErrorMessage != nil },
            set: { if !$0 { commandErrorMessage = nil } }
        )
    }
}
