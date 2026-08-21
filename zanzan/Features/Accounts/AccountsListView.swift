import SwiftData
import SwiftUI

/// 账户管理：按大类分组 + 已归档折叠区；余额行内派生。
struct AccountsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Account> { !$0.isSoftDeleted }, sort: \Account.sortOrder)
    private var accounts: [Account]

    @State private var isAddingAccount = false
    @State private var commandErrorMessage: String?
    @State private var pendingDeletionID: UUID?

    private var groups: [(kind: AccountKind, accounts: [Account])] {
        let active = accounts.filter { !$0.isArchived }
        return AccountKind.allCases.compactMap { kind in
            let items = active.filter { $0.kind == kind }
            return items.isEmpty ? nil : (kind, items)
        }
    }

    private var archivedAccounts: [Account] { accounts.filter(\.isArchived) }

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
        .accessibilityIdentifier("screen.accounts")
        .zanzanCompactList()
        .zanzanSketchPageBackground()
        .overlay {
            if accounts.isEmpty {
                ContentUnavailableView("还没有账户", systemImage: "creditcard", description: Text("点右上角添加账户"))
            }
        }
        .navigationTitle("账户管理")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("添加账户", systemImage: "plus") { isAddingAccount = true }
                    .buttonStyle(.glassProminent)
            }
        }
        .sheet(isPresented: $isAddingAccount) {
            AccountFormView(title: ZanzanLocalization.string( "添加账户"), draft: AccountDraft()) { draft in
                try AccountService(context: modelContext).createAccount(draft)
            }
        }
        .alert("操作失败", isPresented: isPresentingError) { } message: {
            Text(commandErrorMessage ?? "")
        }
    }

    private func row(for account: Account) -> some View {
        NavigationLink {
            AccountDetailView(account: account)
        } label: {
            HStack(spacing: ZanzanStyle.compactRowSpacing) {
                AccountIconView(account: account, size: ZanzanStyle.compactRowIconSize)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                    if !account.subtitle.isEmpty {
                        Text(account.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                switch balanceResult(of: account) {
                case let .success(balance):
                    Text(formatAmount(balance, currencyCode: account.currencyCode))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                case .failure:
                    Text("余额读取失败")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .confirmationDialog(
            "删除这个账户？",
            isPresented: deletionBinding(for: account.uuid),
            titleVisibility: .visible
        ) {
            Button("删除账户", role: .destructive) {
                run { try AccountService(context: modelContext).softDeleteAccount(uuid: account.uuid) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后将不再显示该账户。存在关联流水或计划时，系统会阻止删除。")
        }
        .swipeActions(edge: .trailing) {
            Button("删除", systemImage: "trash", role: .destructive) {
                pendingDeletionID = account.uuid
            }
            Button(account.isArchived ? ZanzanLocalization.string( "取消归档") : ZanzanLocalization.string( "归档"),
                   systemImage: account.isArchived ? "tray.and.arrow.up" : "archivebox") {
                run { try AccountService(context: modelContext).setArchived(uuid: account.uuid, isArchived: !account.isArchived) }
            }
        }
    }

    /// ponytail: 每行一次全量求和，账户/流水量级上来再走快照缓存。
    /// 读取失败必须显式披露，不能把期初余额伪装成当前余额。
    private func balanceResult(of account: Account) -> Result<Int, any Error> {
        Result { try AccountBalanceProvider(context: modelContext).balanceMinorUnits(of: account) }
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
