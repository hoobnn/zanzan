import SwiftData
import SwiftUI

/// 资产 Tab 首页：净资产总览 + 借入借出 + 按大类分组的账户列表（钱迹风格）。
struct AssetsHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(filter: #Predicate<Account> { !$0.isSoftDeleted }, sort: \Account.sortOrder)
    private var accounts: [Account]
    /// ponytail: 仅作余额失效信号——余额在投影内派生，流水变动时借它触发重算。
    @Query(filter: #Predicate<Transaction> { !$0.isSoftDeleted })
    private var transactions: [Transaction]

    @AppStorage("hidesAssetAmounts") private var hidesAmounts = false
    @State private var collapsedKinds: Set<AccountKind> = []
    @State private var isAddingAccount = false
    @State private var isShowingManagement = false

    private var overviewResult: Result<AssetsOverview, any Error> {
        _ = (accounts.count, transactions.count) // 声明对两组数据的依赖
        return Result { try AssetsOverviewProvider(context: modelContext).overview() }
    }

    var body: some View {
        Group {
            switch overviewResult {
            case let .success(overview):
                overviewList(overview)
            case let .failure(error):
                ContentUnavailableView(
                    "资产读取失败",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error.localizedDescription)
                )
            }
        }
        .zanzanSketchPageBackground()
        .navigationTitle("资产")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("添加账户", systemImage: "plus") { isAddingAccount = true }
                    .buttonStyle(.glassProminent)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("账户管理", systemImage: "ellipsis") { isShowingManagement = true }
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                // ponytail: 用 NavigationLink 直推——isPresented push 的页内再做 value push 会被弹回。
                AvatarToolbarLink()
            }
        }
        .navigationDestination(isPresented: $isShowingManagement) {
            AccountsListView()
        }
        .sheet(isPresented: $isAddingAccount) {
            AccountFormView(title: ZanzanLocalization.string( "添加账户"), draft: AccountDraft()) { draft in
                try AccountService(context: modelContext).createAccount(draft)
            }
        }
    }

    private func overviewList(_ overview: AssetsOverview) -> some View {
        List {
            netWorthSection(overview)
            if !overview.fxFallbackCurrencyCodes.isEmpty {
                fxFallbackSection(overview.fxFallbackCurrencyCodes)
            }
            loanSection(overview)
            ForEach(overview.groups, id: \.kind) { group in
                groupSection(group)
            }
        }
        .listSectionSpacing(ZanzanStyle.sketchSectionSpacing)
        .contentMargins(.top, 0, for: .scrollContent)
        .overlay {
            if accounts.isEmpty {
                ContentUnavailableView("还没有账户", systemImage: "creditcard", description: Text("点右上角添加账户"))
            }
        }
    }

    private func fxFallbackSection(_ currencyCodes: Set<String>) -> some View {
        Section {
            Label {
                Text(
                    "缺少 \(currencyCodes.sorted().joined(separator: ", ")) 汇率快照，跨币种汇总暂按 1:1 折算"
                )
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.footnote)
            .foregroundStyle(.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .zanzanSketchCard(tint: .orange)
            .accessibilityHint("录入对应币种流水汇率后，资产汇总会自动按最新快照折算")
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - 净资产卡

    private func netWorthSection(_ overview: AssetsOverview) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("净资产")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.zanzanMint.opacity(0.14), in: .capsule)
                    Button(hidesAmounts ? ZanzanLocalization.string( "显示金额") : ZanzanLocalization.string( "隐藏金额"),
                           systemImage: hidesAmounts ? "eye.slash.fill" : "eye.fill") {
                        hidesAmounts.toggle()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                Text(money(overview.netWorthMinorUnits))
                    .font(.title)
                    .bold()
                    .monospacedDigit()
                    .contentTransition(.numericText())
                HStack(spacing: 16) {
                    labeledAmount("总资产", overview.totalAssetsMinorUnits)
                    labeledAmount("总负债", overview.totalLiabilitiesMinorUnits)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .zanzanSketchCard(tint: .zanzanMint)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
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
                         symbol: "arrow.down", tint: .zanzanExpense)
                loanCard("总借出", amount: overview.lentTotalMinorUnits,
                         symbol: "arrow.up", tint: .zanzanIncome)
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
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 10).fill(tint))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Text(money(amount)).font(.headline).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .zanzanSketchCard(tint: tint)
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
            if reduceMotion {
                toggleGroup(group.kind)
            } else {
                withAnimation {
                    toggleGroup(group.kind)
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
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsedKinds.contains(group.kind) ? -90 : 0))
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(.rect)
        .textCase(nil)
        .accessibilityHint(collapsedKinds.contains(group.kind) ? ZanzanLocalization.string( "展开分组") : ZanzanLocalization.string( "折叠分组"))
    }

    private func toggleGroup(_ kind: AccountKind) {
        if !collapsedKinds.insert(kind).inserted {
            collapsedKinds.remove(kind)
        }
    }

    private func groupSummary(_ group: AssetsOverview.Group) -> String {
        var parts = [ZanzanLocalization.string( "余额: \(money(group.balanceTotalMinorUnits))")]
        if group.debtTotalMinorUnits > 0 {
            parts.append(ZanzanLocalization.string( "欠款: \(money(group.debtTotalMinorUnits))"))
        }
        return parts.joined(separator: "  ")
    }

    private func accountRow(_ item: AssetsOverview.Item) -> some View {
        NavigationLink {
            AccountDetailView(account: item.account)
        } label: {
            HStack(spacing: 10) {
                AccountIconView(account: item.account, size: 40)
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
                Text(money(item.balanceMinorUnits, currencyCode: item.account.currencyCode))
                    .font(.body.weight(.medium))
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 52)
            .zanzanSketchCard(tint: .zanzanSky)
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
        .listRowBackground(Color.clear)
    }

    /// 金额展示统一走这里，支持一键隐藏。
    private func money(
        _ minorUnits: Int,
        currencyCode: String = FxConversion.baseCurrencyCode
    ) -> String {
        guard !hidesAmounts else {
            return currencyCode == FxConversion.baseCurrencyCode
                ? "¥ ****"
                : "\(currencyCode) ****"
        }
        return formatAmount(minorUnits, currencyCode: currencyCode)
    }
}

#Preview {
    NavigationStack { AssetsHomeView() }
}
