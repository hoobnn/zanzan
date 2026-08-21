import SwiftData
import SwiftUI

struct InstallmentDetailView: View {
    let plan: InstallmentPlan

    @Environment(\.modelContext) private var modelContext
    @Query private var periods: [InstallmentPeriod]
    @Query(filter: #Predicate<Transaction> { !$0.isSoftDeleted })
    private var transactions: [Transaction]
    @Query(filter: #Predicate<Account> { !$0.isSoftDeleted })
    private var accounts: [Account]

    @State private var settlingPeriod: InstallmentPeriod?
    @State private var isSettlingEarly = false
    @State private var commandErrorMessage: String?
    @State private var pendingUndo: PendingUndo?

    private enum PendingUndo {
        case period(Int)
        case earlySettlement
    }

    init(plan: InstallmentPlan) {
        self.plan = plan
        let id = plan.uuid
        _periods = Query(
            filter: #Predicate<InstallmentPeriod> { !$0.isSoftDeleted && $0.planID == id },
            sort: \InstallmentPeriod.periodIndex
        )
    }

    private var progressResult: Result<InstallmentPlanProgress, Error> {
        _ = (periods.count, transactions.count)
        return Result {
            try InstallmentPlanProvider(context: modelContext).progress(planUUID: plan.uuid)
        }
    }

    private var currencyCode: String {
        accounts.first { $0.uuid == plan.accountID }?.currencyCode ?? "CNY"
    }

    private var earliestPendingPeriodID: UUID? {
        periods.first { $0.status == .pending }?.uuid
    }

    private var latestSettledPeriodID: UUID? {
        periods.last { $0.status == .settled }?.uuid
    }

    var body: some View {
        List {
            Section {
                switch progressResult {
                case let .success(progress):
                    VStack(alignment: .leading, spacing: 12) {
                        Text("剩余本金")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(
                            formatAmount(
                                progress.remainingPrincipalMinorUnits,
                                currencyCode: currencyCode
                            )
                        )
                            .font(.system(.title, design: .rounded, weight: .bold))
                            .monospacedDigit()
                        ProgressView(
                            value: Double(progress.paidPrincipalMinorUnits),
                            total: Double(max(plan.principalMinorUnits, 1))
                        )
                        Text(
                            "已还 \(progress.settledPeriodCount)/\(progress.totalPeriods) 期 · 剩余息费 \(formatAmount(progress.remainingInterestMinorUnits, currencyCode: currencyCode))"
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .zanzanSketchCard(tint: .zanzanSun)
                case let .failure(error):
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            if plan.amortizationKind == .flatFee {
                Section("计算规则") {
                    if let totalCharge = plan.totalChargeMinorUnits {
                        LabeledContent(
                            "息费总额",
                            value: formatAmount(totalCharge, currencyCode: currencyCode)
                        )
                    }
                    LabeledContent("息费收取", value: chargeCollectionText)
                    LabeledContent("本金取整", value: roundingText(plan.principalRoundingKind))
                    LabeledContent("本金尾差", value: remainderText(plan.principalRemainderKind))
                    if plan.chargeCollectionKind == .perPeriod {
                        LabeledContent("息费取整", value: roundingText(plan.chargeRoundingKind))
                        LabeledContent("息费尾差", value: remainderText(plan.chargeRemainderKind))
                    }
                }
            }

            Section("期数") {
                ForEach(periods) { period in
                    periodRow(period)
                        .swipeActions(edge: .leading) {
                            if period.uuid == earliestPendingPeriodID && plan.status == .active {
                                Button("记一期", systemImage: "checkmark.circle") {
                                    settlingPeriod = period
                                }
                                .tint(.zanzanExpense)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            if period.uuid == latestSettledPeriodID && plan.status != .settledEarly {
                                Button("撤销还款", systemImage: "arrow.uturn.backward", role: .destructive) {
                                    pendingUndo = .period(period.periodIndex)
                                }
                            }
                        }
                }
            }
        }
        .zanzanCompactList()
        .zanzanSketchPageBackground()
        .navigationTitle(plan.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if plan.status == .active {
                    Button("提前结清", systemImage: "checkmark.seal") {
                        isSettlingEarly = true
                    }
                } else if plan.status == .settledEarly {
                    Button("撤销结清", systemImage: "arrow.uturn.backward") {
                        pendingUndo = .earlySettlement
                    }
                }
            }
        }
        .sheet(item: $settlingPeriod) { period in
            InstallmentSettlementView(plan: plan, periodIndex: period.periodIndex)
        }
        .sheet(isPresented: $isSettlingEarly) {
            InstallmentSettlementView(plan: plan, periodIndex: nil)
        }
        .confirmationDialog(
            "确认撤销还款？",
            isPresented: Binding(
                get: { pendingUndo != nil },
                set: { if !$0 { pendingUndo = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("撤销并删除还款流水", role: .destructive) {
                guard let pendingUndo else { return }
                self.pendingUndo = nil
                run {
                    let service = InstallmentService(context: modelContext)
                    switch pendingUndo {
                    case let .period(index):
                        try service.undoSettlePeriod(
                            planUUID: plan.uuid, periodIndex: index, at: .now
                        )
                    case .earlySettlement:
                        try service.undoSettleEarly(planUUID: plan.uuid, at: .now)
                    }
                }
            }
            Button("取消", role: .cancel) { pendingUndo = nil }
        } message: {
            Text("对应还款流水会被移入最近删除，账户余额与分期进度将同步回退。")
        }
        .alert("操作失败", isPresented: isPresentingError) { } message: {
            Text(commandErrorMessage ?? "")
        }
    }

    private func periodRow(_ period: InstallmentPeriod) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("第 \(period.periodIndex) 期")
                Text(ZanzanLocalization.formatted(period.dueAt, date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(
                    formatAmount(
                        period.principalMinorUnits + period.interestMinorUnits,
                        currencyCode: currencyCode
                    )
                )
                    .monospacedDigit()
                Text(periodStatus(period))
                    .font(.caption)
                    .foregroundStyle(
                        period.status == .pending
                            ? AnyShapeStyle(.secondary)
                            : AnyShapeStyle(.tint)
                    )
            }
        }
    }

    private func periodStatus(_ period: InstallmentPeriod) -> String {
        switch period.status {
        case .pending: ZanzanLocalization.string( "待还")
        case .settled: ZanzanLocalization.string( "已还")
        case .cancelled: ZanzanLocalization.string( "已结清")
        case nil: ZanzanLocalization.string( "未知状态")
        }
    }

    private var chargeCollectionText: String {
        switch plan.chargeCollectionKind {
        case .perPeriod: ZanzanLocalization.string("分期收取")
        case .upfrontFirstPeriod: ZanzanLocalization.string("首期一次收取")
        case nil: ZanzanLocalization.string("未知规则")
        }
    }

    private func roundingText(_ kind: InstallmentRoundingKind?) -> String {
        switch kind {
        case .downToMinorUnit: ZanzanLocalization.string("向下精确到分")
        case .nearestMinorUnit: ZanzanLocalization.string("四舍五入到分")
        case .nearestMajorUnit: ZanzanLocalization.string("四舍五入到元")
        case nil: ZanzanLocalization.string("未知规则")
        }
    }

    private func remainderText(_ kind: InstallmentRemainderKind?) -> String {
        switch kind {
        case .firstPeriod: ZanzanLocalization.string("归首期")
        case .lastPeriod: ZanzanLocalization.string("归末期")
        case nil: ZanzanLocalization.string("未知规则")
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
