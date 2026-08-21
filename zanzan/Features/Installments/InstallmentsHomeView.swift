import SwiftData
import SwiftUI

struct InstallmentsHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<InstallmentPlan> { !$0.isSoftDeleted }, sort: \InstallmentPlan.firstDueAt)
    private var plans: [InstallmentPlan]
    @Query(filter: #Predicate<InstallmentPeriod> { !$0.isSoftDeleted })
    private var periods: [InstallmentPeriod]
    @Query(filter: #Predicate<Transaction> { !$0.isSoftDeleted })
    private var transactions: [Transaction]
    @Query(filter: #Predicate<Account> { !$0.isSoftDeleted })
    private var accounts: [Account]

    @State private var isAddingPlan = false
    @State private var commandErrorMessage: String?
    @State private var planPendingDeletion: InstallmentPlan?

    var body: some View {
        List {
            ForEach(plans) { plan in
                NavigationLink {
                    InstallmentDetailView(plan: plan)
                } label: {
                    HStack(spacing: ZanzanStyle.compactRowSpacing) {
                        Image(systemName: plan.kind == .loan ? "house.fill" : "calendar.badge.clock")
                            .foregroundStyle(.tint)
                            .frame(
                                width: ZanzanStyle.compactRowIconSize,
                                height: ZanzanStyle.compactRowIconSize
                            )
                            .background {
                                Circle()
                                    .fill(.tint)
                                    .opacity(0.18)
                            }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plan.name)
                            progressText(plan)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(planStatus(plan))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button("删除", systemImage: "trash", role: .destructive) {
                        planPendingDeletion = plan
                    }
                }
            }
        }
        .overlay {
            if plans.isEmpty {
                ContentUnavailableView(
                    "还没有分期计划",
                    systemImage: "calendar.badge.clock",
                    description: Text("消费分期、账单分期和贷款可以按期管理")
                )
            }
        }
        .accessibilityIdentifier("screen.installments")
        .zanzanCompactList()
        .zanzanSketchPageBackground()
        .navigationTitle("分期与贷款")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("新建计划", systemImage: "plus") {
                    isAddingPlan = true
                }
                .buttonStyle(.glassProminent)
            }
        }
        .sheet(isPresented: $isAddingPlan) {
            InstallmentPlanFormView { draft in
                try InstallmentService(context: modelContext).createPlan(draft)
            }
        }
        .confirmationDialog(
            "删除分期计划？",
            isPresented: Binding(
                get: { planPendingDeletion != nil },
                set: { if !$0 { planPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除计划", role: .destructive) {
                guard let plan = planPendingDeletion else { return }
                planPendingDeletion = nil
                run {
                    try InstallmentService(context: modelContext)
                        .softDeletePlan(uuid: plan.uuid, at: .now)
                }
            }
            Button("取消", role: .cancel) { planPendingDeletion = nil }
        } message: {
            Text("计划和期数日程会被移入最近删除；已经生成的账户流水不会被改动。")
        }
        .alert("操作失败", isPresented: isPresentingError) { } message: {
            Text(commandErrorMessage ?? "")
        }
    }

    @ViewBuilder
    private func progressText(_ plan: InstallmentPlan) -> some View {
        let _ = (periods.count, transactions.count)
        switch Result(catching: {
            try InstallmentPlanProvider(context: modelContext).progress(planUUID: plan.uuid)
        }) {
        case let .success(progress):
            Text(
                "已还 \(progress.settledPeriodCount)/\(progress.totalPeriods) 期 · 剩余 \(formatAmount(progress.remainingPrincipalMinorUnits, currencyCode: currencyCode(for: plan)))"
            )
        case .failure:
            Text("进度读取失败")
                .foregroundStyle(.red)
        }
    }

    private func currencyCode(for plan: InstallmentPlan) -> String {
        accounts.first { $0.uuid == plan.accountID }?.currencyCode ?? "CNY"
    }

    private func planStatus(_ plan: InstallmentPlan) -> String {
        switch plan.status {
        case .active: ZanzanLocalization.string( "进行中")
        case .completed: ZanzanLocalization.string( "已完成")
        case .settledEarly: ZanzanLocalization.string( "已提前结清")
        case nil: ZanzanLocalization.string( "未知状态")
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
