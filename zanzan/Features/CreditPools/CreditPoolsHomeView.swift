import SwiftData
import SwiftUI

struct CreditPoolsHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<CreditPool> { !$0.isSoftDeleted }, sort: \CreditPool.sortOrder)
    private var pools: [CreditPool]
    @Query(filter: #Predicate<Account> { !$0.isSoftDeleted })
    private var accounts: [Account]
    @Query(filter: #Predicate<Transaction> { !$0.isSoftDeleted })
    private var transactions: [Transaction]

    @State private var isAddingPool = false
    @State private var commandErrorMessage: String?
    @State private var poolPendingDeletion: CreditPool?

    var body: some View {
        List {
            ForEach(pools) { pool in
                NavigationLink {
                    CreditPoolDetailView(pool: pool)
                } label: {
                    HStack(spacing: ZanzanStyle.compactRowSpacing) {
                        AccountIconView(
                            name: pool.name,
                            subtitle: pool.name,
                            kind: .credit,
                            size: ZanzanStyle.compactRowIconSize
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pool.name)
                            overviewText(pool)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .swipeActions {
                    Button("删除", systemImage: "trash", role: .destructive) {
                        poolPendingDeletion = pool
                    }
                }
            }
        }
        .overlay {
            if pools.isEmpty {
                ContentUnavailableView(
                    "还没有授信池",
                    systemImage: "creditcard.and.123",
                    description: Text("同一银行的多张信用卡可以共享一个总额度")
                )
            }
        }
        .accessibilityIdentifier("screen.creditPools")
        .zanzanCompactList()
        .zanzanSketchPageBackground()
        .navigationTitle("授信池")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("新建授信池", systemImage: "plus") {
                    isAddingPool = true
                }
                .buttonStyle(.glassProminent)
            }
        }
        .sheet(isPresented: $isAddingPool) {
            CreditPoolFormView(title: ZanzanLocalization.string( "新建授信池"), draft: CreditPoolDraft()) { draft in
                try CreditPoolService(context: modelContext).createPool(draft)
            }
        }
        .confirmationDialog(
            "删除授信池？",
            isPresented: Binding(
                get: { poolPendingDeletion != nil },
                set: { if !$0 { poolPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除授信池", role: .destructive) {
                guard let pool = poolPendingDeletion else { return }
                poolPendingDeletion = nil
                run { try CreditPoolService(context: modelContext).softDeletePool(uuid: pool.uuid) }
            }
            Button("取消", role: .cancel) { poolPendingDeletion = nil }
        } message: {
            Text("授信池会被移入最近删除；成员卡将暂按各自额度计算，恢复后会重新生效。")
        }
        .alert("操作失败", isPresented: isPresentingError) { } message: {
            Text(commandErrorMessage ?? "")
        }
    }

    @ViewBuilder
    private func overviewText(_ pool: CreditPool) -> some View {
        let _ = (accounts.count, transactions.count)
        switch Result(catching: {
            try CreditPoolProvider(context: modelContext).overview(poolUUID: pool.uuid)
        }) {
        case let .success(overview):
            Text(
                "可用 \(formatAmount(overview.availableMinorUnits, currencyCode: overview.pool.currencyCode)) / \(formatAmount(overview.totalLimitMinorUnits, currencyCode: overview.pool.currencyCode))"
            )
        case .failure:
            Text("额度读取失败")
                .foregroundStyle(.red)
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
