import SwiftData
import SwiftUI

struct CategoriesHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Category> { !$0.isSoftDeleted }, sort: \Category.sortOrder)
    private var categories: [Category]
    @Query(
        filter: #Predicate<Ledger> { !$0.isSoftDeleted && !$0.isArchived },
        sort: \Ledger.sortOrder
    )
    private var ledgers: [Ledger]

    @State private var selectedKind = TransactionKind.expense
    @State private var selectedLedgerID: UUID?
    @State private var isAddingCategory = false
    @State private var editingCategory: Category?
    @State private var isConfirmingRestore = false
    @State private var commandErrorMessage: String?
    @State private var categoryPendingDeletion: Category?

    private var treeResult: Result<[CategoryTreeNode], Error> {
        _ = categories.count
        return Result {
            try CategoryTreeProvider(context: modelContext)
                .tree(
                    kind: selectedKind,
                    ledgerID: selectedLedgerID,
                    includeArchived: true
                )
        }
    }

    var body: some View {
        List {
            Section {
                Picker("收支类型", selection: $selectedKind) {
                    Text(TransactionKind.expense.displayName).tag(TransactionKind.expense)
                    Text(TransactionKind.income.displayName).tag(TransactionKind.income)
                }
                .pickerStyle(.segmented)
                .zanzanControlSurface()
                Picker("适用账本", selection: $selectedLedgerID) {
                    Text("全部账本").tag(UUID?.none)
                    ForEach(ledgers) { ledger in
                        Text(ledger.name).tag(ledger.uuid as UUID?)
                    }
                }
                .zanzanControlSurface()
            }

            switch treeResult {
            case let .success(nodes) where nodes.isEmpty:
                Section {
                    ContentUnavailableView(
                        "还没有分类",
                        systemImage: "square.grid.2x2",
                        description: Text("点右上角新建第一个分类")
                    )
                    .listRowBackground(Color.clear)
                }
            case let .success(nodes):
                Section {
                    ForEach(nodes, id: \.category.uuid) { node in
                        categoryRow(node.category, isChild: false)
                        ForEach(node.children) { child in
                            categoryRow(child, isChild: true)
                        }
                    }
                }
            case let .failure(error):
                Section {
                    ContentUnavailableView(
                        "分类读取失败",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error.localizedDescription)
                    )
                    .listRowBackground(Color.clear)
                }
            }
        }
        .accessibilityIdentifier("screen.categories")
        .zanzanCompactList()
        .zanzanSketchPageBackground()
        .navigationTitle("分类管理")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("更多", systemImage: "ellipsis") {
                    Button("恢复默认分类", systemImage: "arrow.counterclockwise") {
                        isConfirmingRestore = true
                    }
                }
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .primaryAction) {
                Button("新建分类", systemImage: "plus") {
                    isAddingCategory = true
                }
                .buttonStyle(.glassProminent)
            }
        }
        .sheet(isPresented: $isAddingCategory) {
            CategoryFormView(
                title: ZanzanLocalization.string( "新建分类"),
                draft: CategoryDraft(kind: selectedKind, ledgerID: selectedLedgerID)
            ) { draft in
                try CategoryService(context: modelContext).createCategory(draft)
            }
        }
        .sheet(item: $editingCategory) { category in
            CategoryFormView(
                title: ZanzanLocalization.string( "编辑分类"),
                draft: CategoryDraft(category: category),
                editingUUID: category.uuid
            ) { draft in
                try CategoryService(context: modelContext)
                    .updateCategory(uuid: category.uuid, draft: draft)
            }
        }
        .confirmationDialog(
            "恢复系统预置分类？",
            isPresented: $isConfirmingRestore,
            titleVisibility: .visible
        ) {
            Button("恢复默认分类") {
                run { try CategoryService(context: modelContext).restoreDefaultCategories() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会恢复被归档或删除的预置分类，不会覆盖你修改过的名称和图标。")
        }
        .confirmationDialog(
            "删除分类？",
            isPresented: Binding(
                get: { categoryPendingDeletion != nil },
                set: { if !$0 { categoryPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除分类", role: .destructive) {
                guard let category = categoryPendingDeletion else { return }
                categoryPendingDeletion = nil
                run { try CategoryService(context: modelContext).softDeleteCategory(uuid: category.uuid) }
            }
            Button("取消", role: .cancel) { categoryPendingDeletion = nil }
        } message: {
            Text("分类会被移入最近删除；关联预算也会一并移入最近删除。")
        }
        .alert("操作失败", isPresented: isPresentingError) { } message: {
            Text(commandErrorMessage ?? "")
        }
    }

    private func categoryRow(_ category: Category, isChild: Bool) -> some View {
        Button {
            editingCategory = category
        } label: {
            HStack(spacing: ZanzanStyle.compactRowSpacing) {
                CategoryIconView(category: category, size: ZanzanStyle.compactRowIconSize - 4)
                    .opacity(category.isArchived ? 0.45 : 1)
                    .frame(
                        width: ZanzanStyle.compactRowIconSize,
                        height: ZanzanStyle.compactRowIconSize
                    )
                    .background {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(.thinMaterial)
                            .opacity(category.isArchived ? 0.08 : 0.18)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(category.name)
                        .foregroundStyle(category.isArchived ? .secondary : .primary)
                    if category.isArchived {
                        Text("已归档")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if category.isBuiltIn {
                    Text("预置")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, isChild ? 20 : 0)
            .contentShape(.rect)
        }
        .contextMenu {
            Button("上移", systemImage: "arrow.up") {
                move(category, offset: -1)
            }
            Button("下移", systemImage: "arrow.down") {
                move(category, offset: 1)
            }
        }
        .swipeActions(edge: .leading) {
            Button(category.isArchived ? "取消归档" : "归档", systemImage: category.isArchived ? "tray.and.arrow.up" : "archivebox") {
                run {
                    try CategoryService(context: modelContext)
                        .setArchived(uuid: category.uuid, isArchived: !category.isArchived)
                }
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing) {
            Button("删除", systemImage: "trash", role: .destructive) {
                categoryPendingDeletion = category
            }
        }
    }

    private func move(_ category: Category, offset: Int) {
        guard case let .success(nodes) = treeResult else { return }
        let siblings = category.parentID == nil
            ? nodes.map(\.category)
            : nodes.first(where: { $0.category.uuid == category.parentID })?.children ?? []
        guard let source = siblings.firstIndex(where: { $0.uuid == category.uuid }) else { return }
        let destination = source + offset
        guard siblings.indices.contains(destination) else { return }
        var ordered = siblings.map(\.uuid)
        ordered.swapAt(source, destination)
        run { try CategoryService(context: modelContext).reorderCategories(orderedUUIDs: ordered) }
    }

    private func run(_ command: () throws -> Void) {
        do {
            try command()
        } catch {
            commandErrorMessage = error.localizedDescription
        }
    }

    private var isPresentingError: Binding<Bool> {
        Binding(
            get: { commandErrorMessage != nil },
            set: { if !$0 { commandErrorMessage = nil } }
        )
    }
}
