import SwiftData
import SwiftUI

/// 账户管理：按大类分组 + 已归档折叠区；余额行内派生。
struct AccountsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<StoredAccount> { !$0.isSoftDeleted }, sort: \StoredAccount.sortOrder)
    private var accounts: [StoredAccount]

    @State private var isAddingAccount = false
    @State private var editingAccount: StoredAccount?
    @State private var commandErrorMessage: String?

    private var groups: [(kind: AccountKind, accounts: [StoredAccount])] {
        let active = accounts.filter { !$0.isArchived }
        return AccountKind.allCases.compactMap { kind in
            let items = active.filter { $0.kind == kind }
            return items.isEmpty ? nil : (kind, items)
        }
    }

    private var archivedAccounts: [StoredAccount] { accounts.filter(\.isArchived) }

    var body: some View {
        List {
            ForEach(groups, id: \.kind) { group in
                Section(group.kind.displayName) {
                    ForEach(group.accounts) { account in
                        row(for: account)
                    }
                }
            }
            if !archivedAccounts.isEmpty {
                Section("已归档") {
                    ForEach(archivedAccounts) { account in
                        row(for: account)
                    }
                }
            }
        }
        .overlay {
            if accounts.isEmpty {
                ContentUnavailableView("还没有账户", systemImage: "creditcard", description: Text("点右上角添加账户"))
            }
        }
        .navigationTitle("账户管理")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("添加账户", systemImage: "plus") { isAddingAccount = true }
            }
        }
        .sheet(isPresented: $isAddingAccount) {
            AccountFormView(title: String(localized: "添加账户"), draft: AccountDraft()) { draft in
                try AccountCommands(context: modelContext).createAccount(draft)
            }
        }
        .sheet(item: $editingAccount) { account in
            AccountFormView(title: String(localized: "编辑账户"), draft: AccountDraft(account: account)) { draft in
                try AccountCommands(context: modelContext).updateAccount(uuid: account.uuid, draft: draft)
            }
        }
        .alert("操作失败", isPresented: isPresentingError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(commandErrorMessage ?? "")
        }
    }

    private func row(for account: StoredAccount) -> some View {
        Button {
            editingAccount = account
        } label: {
            HStack {
                Image(systemName: (account.kind ?? .fund).symbolName)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text(account.name)
                    if !account.subtitle.isEmpty {
                        Text(account.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(formatAmount(balanceMinorUnits(of: account)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .tint(.primary)
        .swipeActions(edge: .trailing) {
            Button("删除", systemImage: "trash", role: .destructive) {
                run { try AccountCommands(context: modelContext).softDeleteAccount(uuid: account.uuid) }
            }
            Button(account.isArchived ? String(localized: "取消归档") : String(localized: "归档"),
                   systemImage: account.isArchived ? "tray.and.arrow.up" : "archivebox") {
                run { try AccountCommands(context: modelContext).setArchived(uuid: account.uuid, isArchived: !account.isArchived) }
            }
        }
    }

    /// ponytail: 每行一次全量求和，账户/流水量级上来再走快照缓存。
    /// 读路径自愈：投影失败回落期初余额展示，不 crash。
    private func balanceMinorUnits(of account: StoredAccount) -> Int {
        (try? AccountBalanceProjector(context: modelContext).balanceMinorUnits(of: account))
            ?? account.initialBalanceMinorUnits
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
