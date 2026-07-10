import SwiftData
import SwiftUI

/// 资产 Tab 首页：净资产总览 + 借入借出 + 按大类分组的账户列表（钱迹风格）。
struct AssetsHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<StoredAccount> { !$0.isSoftDeleted }, sort: \StoredAccount.sortOrder)
    private var accounts: [StoredAccount]
    /// ponytail: 仅作余额失效信号——余额在投影内派生，流水变动时借它触发重算。
    @Query(filter: #Predicate<StoredTransaction> { !$0.isSoftDeleted })
    private var transactions: [StoredTransaction]

    @AppStorage("hidesAssetAmounts") private var hidesAmounts = false
    @State private var collapsedKinds: Set<AccountKind> = []
    @State private var isAddingAccount = false
    @State private var editingAccount: StoredAccount?
    @State private var isShowingManagement = false

    private var overview: AssetsOverview {
        _ = (accounts.count, transactions.count) // 声明对两组数据的依赖
        return (try? AssetsOverviewProjector(context: modelContext).overview())
            ?? AssetsOverview(groups: [], totalAssetsMinorUnits: 0, totalLiabilitiesMinorUnits: 0,
                              borrowedTotalMinorUnits: 0, lentTotalMinorUnits: 0)
    }

    var body: some View {
        let overview = overview
        List {
            netWorthSection(overview)
            loanSection(overview)
            ForEach(overview.groups, id: \.kind) { group in
                groupSection(group)
            }
        }
        .overlay {
            if accounts.isEmpty {
                ContentUnavailableView("还没有账户", systemImage: "creditcard", description: Text("点右上角添加账户"))
            }
        }
        .navigationTitle("资产")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("账户管理", systemImage: "ellipsis") { isShowingManagement = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("添加账户", systemImage: "plus") { isAddingAccount = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // ponytail: 用 NavigationLink 直推——isPresented push 的页内再做 value push 会被弹回。
                NavigationLink {
                    SettingsHomeView()
                } label: {
                    Label("我的", systemImage: "person.crop.circle")
                }
            }
        }
        .navigationDestination(isPresented: $isShowingManagement) {
            AccountsListView()
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
    }

    // MARK: - 净资产卡

    private func netWorthSection(_ overview: AssetsOverview) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("净资产")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button(hidesAmounts ? String(localized: "显示金额") : String(localized: "隐藏金额"),
                           systemImage: hidesAmounts ? "eye.slash.fill" : "eye.fill") {
                        hidesAmounts.toggle()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                Text(money(overview.netWorthMinorUnits))
                    .font(.system(size: 40, weight: .heavy))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                HStack(spacing: 24) {
                    labeledAmount("总资产", overview.totalAssetsMinorUnits)
                    labeledAmount("总负债", overview.totalLiabilitiesMinorUnits)
                }
            }
            .padding(.vertical, 10)
        }
    }

    private func labeledAmount(_ title: LocalizedStringKey, _ minorUnits: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.tertiary)
            Text(money(minorUnits)).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.subheadline)
    }

    // MARK: - 借入/借出卡

    private func loanSection(_ overview: AssetsOverview) -> some View {
        Section {
            HStack(spacing: 12) {
                loanCard("总借入", amount: overview.borrowedTotalMinorUnits,
                         symbol: "arrow.down", tint: Color(.darkGray))
                loanCard("总借出", amount: overview.lentTotalMinorUnits,
                         symbol: "arrow.up", tint: .mint)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private func loanCard(_ title: LocalizedStringKey, amount: Int, symbol: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 10).fill(tint))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Text(money(amount)).font(.headline).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }

    // MARK: - 账户分组

    private func groupSection(_ group: AssetsOverview.Group) -> some View {
        Section {
            if !collapsedKinds.contains(group.kind) {
                ForEach(group.items, id: \.account.uuid) { item in
                    accountRow(item)
                }
            }
        } header: {
            groupHeader(group)
        }
    }

    private func groupHeader(_ group: AssetsOverview.Group) -> some View {
        Button {
            withAnimation {
                if !collapsedKinds.insert(group.kind).inserted {
                    collapsedKinds.remove(group.kind)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("\(group.kind.displayName)账户")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("(\(group.items.count))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(groupSummary(group))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsedKinds.contains(group.kind) ? -90 : 0))
            }
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .accessibilityHint(collapsedKinds.contains(group.kind) ? String(localized: "展开分组") : String(localized: "折叠分组"))
    }

    private func groupSummary(_ group: AssetsOverview.Group) -> String {
        var parts = [String(localized: "余额: \(money(group.balanceTotalMinorUnits))")]
        if group.debtTotalMinorUnits > 0 {
            parts.append(String(localized: "欠款: \(money(group.debtTotalMinorUnits))"))
        }
        return parts.joined(separator: "  ")
    }

    private func accountRow(_ item: AssetsOverview.Item) -> some View {
        Button {
            editingAccount = item.account
        } label: {
            HStack(spacing: 12) {
                // ponytail: 银行图标资源预留——先用大类 SF Symbol 占位，icon 四件套资源就位后按账户渲染。
                Image(systemName: (item.account.kind ?? .fund).symbolName)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color(.systemGray6)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.account.name)
                        .font(.headline)
                    if !item.account.subtitle.isEmpty {
                        Text(item.account.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(money(item.balanceMinorUnits))
                    .font(.body.weight(.medium))
                    .monospacedDigit()
            }
        }
        .tint(.primary)
    }

    /// 金额展示统一走这里，支持一键隐藏。
    private func money(_ minorUnits: Int) -> String {
        hidesAmounts ? "¥ ****" : formatAmount(minorUnits)
    }
}

#Preview {
    NavigationStack { AssetsHomeView() }
}
