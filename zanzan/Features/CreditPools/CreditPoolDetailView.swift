import SwiftData
import SwiftUI

struct CreditPoolDetailView: View {
    let pool: CreditPool

    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Account> { !$0.isSoftDeleted }, sort: \Account.sortOrder)
    private var accounts: [Account]
    @Query(filter: #Predicate<Transaction> { !$0.isSoftDeleted })
    private var transactions: [Transaction]

    @State private var isEditing = false
    @State private var commandErrorMessage: String?

    private var members: [Account] {
        accounts.filter { $0.creditPoolID == pool.uuid }
    }

    private var availableCards: [Account] {
        accounts.filter {
            $0.kind == .credit && $0.currencyCode == pool.currencyCode && $0.creditPoolID != pool.uuid
        }
    }

    private var overviewResult: Result<CreditPoolOverview, Error> {
        _ = (accounts.count, transactions.count)
        return Result {
            try CreditPoolProvider(context: modelContext).overview(poolUUID: pool.uuid)
        }
    }

    var body: some View {
        List {
            Section {
                switch overviewResult {
                case let .success(overview):
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            if let representative = members.first {
                                AccountIconView(account: representative, size: 48)
                            } else {
                                AccountIconView(
                                    name: pool.name,
                                    subtitle: pool.name,
                                    kind: .credit,
                                    size: 48
                                )
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text("剩余额度")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text(
                                    formatAmount(
                                        overview.availableMinorUnits,
                                        currencyCode: overview.pool.currencyCode
                                    )
                                )
                                .font(.system(.title, design: .rounded, weight: .bold))
                                .monospacedDigit()
                            }
                        }
                        ProgressView(value: overview.totalLimitMinorUnits > 0
                                     ? Double(overview.usedMinorUnits) / Double(overview.totalLimitMinorUnits)
                                     : 0)
                            .tint(.zanzanExpense)
                        Text(
                            "已用 \(formatAmount(overview.usedMinorUnits, currencyCode: overview.pool.currencyCode)) · 总额度 \(formatAmount(overview.totalLimitMinorUnits, currencyCode: overview.pool.currencyCode))"
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !overview.currencyMismatchedMemberUUIDs.isEmpty {
                            let names = members
                                .filter { overview.currencyMismatchedMemberUUIDs.contains($0.uuid) }
                                .map(\.name)
                                .sorted()
                                .joined(separator: ", ")
                            Label(
                                "已忽略币种不一致的成员卡：\(names)",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .zanzanSketchCard(tint: .zanzanSky)
                case let .failure(error):
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            Section("成员卡") {
                if members.isEmpty {
                    Text("还没有成员卡")
                        .foregroundStyle(.secondary)
                }
                ForEach(members) { account in
                    HStack {
                        AccountIconView(account: account, size: 32)
                        Text(account.name)
                        Spacer()
                        Button("解绑") {
                            run { try CreditPoolService(context: modelContext).unbindCard(accountUUID: account.uuid) }
                        }
                        .buttonStyle(.borderless)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                    }
                }
            }

            if !availableCards.isEmpty {
                Section("可加入的信用卡") {
                    ForEach(availableCards) { account in
                        Button {
                            run {
                                try CreditPoolService(context: modelContext)
                                    .bindCard(accountUUID: account.uuid, toPool: pool.uuid)
                            }
                        } label: {
                            HStack {
                                AccountIconView(account: account, size: 32)
                                Text("加入 \(account.name)")
                                Spacer()
                                Image(systemName: "plus.circle")
                            }
                        }
                    }
                }
            }
        }
        .zanzanCompactList()
        .zanzanSketchPageBackground()
        .navigationTitle(pool.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("编辑", systemImage: "pencil") {
                    isEditing = true
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            CreditPoolFormView(title: ZanzanLocalization.string( "编辑授信池"), draft: CreditPoolDraft(pool: pool)) { draft in
                try CreditPoolService(context: modelContext).updatePool(uuid: pool.uuid, draft: draft)
            }
        }
        .alert("操作失败", isPresented: isPresentingError) { } message: {
            Text(commandErrorMessage ?? "")
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
