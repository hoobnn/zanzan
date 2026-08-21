import Charts
import SwiftData
import SwiftUI

struct MonthlyStatsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Query private var transactions: [Transaction]

    private let ledgerID: UUID
    @Binding private var monthAnchor: Date

    init(ledgerID: UUID, monthAnchor: Binding<Date>) {
        self.ledgerID = ledgerID
        _monthAnchor = monthAnchor
        let id: UUID? = ledgerID
        let interval = Calendar.current.dateInterval(of: .month, for: monthAnchor.wrappedValue)
        let monthStart = interval?.start ?? .distantPast
        let monthEnd = interval?.end ?? .distantFuture
        _transactions = Query(filter: #Predicate<Transaction> {
            !$0.isSoftDeleted && $0.ledgerID == id
                && $0.occurredAt >= monthStart && $0.occurredAt < monthEnd
        })
    }

    private var statsResult: Result<MonthlyStats, Error> {
        _ = transactions.count
        let components = Calendar.current.dateComponents([.year, .month], from: monthAnchor)
        return Result {
            try MonthlyStatsProvider(context: modelContext).stats(
                ledgerID: ledgerID,
                year: components.year ?? 0,
                month: components.month ?? 0
            )
        }
    }

    var body: some View {
        List {
            monthSelector

            switch statsResult {
            case let .success(stats):
                summarySection(stats)
                if stats.expenseRanking.isEmpty && stats.incomeRanking.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "本月暂无统计",
                            systemImage: "chart.bar.xaxis",
                            description: Text("记账后，这里会按分类汇总收支")
                        )
                        .listRowBackground(Color.clear)
                    }
                } else {
                    expenseChartSection(stats)
                    rankingSection("支出排行", items: stats.expenseRanking, total: stats.expenseTotalMinorUnits, tint: .zanzanExpense)
                    rankingSection("收入排行", items: stats.incomeRanking, total: stats.incomeTotalMinorUnits, tint: .zanzanIncome)
                }
            case let .failure(error):
                Section {
                    ContentUnavailableView(
                        "统计读取失败",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error.localizedDescription)
                    )
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listSectionSpacing(ZanzanStyle.sketchSectionSpacing)
        .contentMargins(.top, 0, for: .scrollContent)
        .zanzanSketchPageBackground()
    }

    private var monthSelector: some View {
        Section {
            HStack(spacing: 8) {
                Text(ZanzanLocalization.formatted(monthAnchor, format: .dateTime.year().month()))
                    .font(.title2.bold())
                Spacer()
                Button("上一月", systemImage: "chevron.left") { shiftMonth(-1) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("上一月")
                Button("下一月", systemImage: "chevron.right") { shiftMonth(1) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("下一月")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .zanzanSketchCard(tint: .zanzanLilac)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private func summarySection(_ stats: MonthlyStats) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("本月结余")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.zanzanMint.opacity(0.14), in: .capsule)
                Text(formatAmount(stats.incomeTotalMinorUnits - stats.expenseTotalMinorUnits, withSign: true))
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)

                HStack {
                    summaryMetric("收入", amount: stats.incomeTotalMinorUnits, color: .zanzanIncome)
                    Divider()
                    summaryMetric("支出", amount: stats.expenseTotalMinorUnits, color: .zanzanExpense)
                }

                if stats.feeTotalMinorUnits > 0 {
                    Label("其中手续费 \(formatAmount(stats.feeTotalMinorUnits))", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .zanzanSketchCard(tint: .zanzanMint)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private func summaryMetric(_ title: LocalizedStringKey, amount: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(formatAmount(amount))
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func expenseChartSection(_ stats: MonthlyStats) -> some View {
        Section("支出构成") {
            Chart(stats.expenseRanking, id: \.category.uuid) { item in
                SectorMark(
                    angle: .value("金额", max(item.totalMinorUnits, 0)),
                    innerRadius: .ratio(0.62),
                    angularInset: 1.5
                )
                .clipShape(.rect(cornerRadius: 4))
                .foregroundStyle(by: .value("分类", item.category.name))
                .annotation(position: .overlay) {
                    if differentiateWithoutColor {
                        Text(item.category.name)
                            .font(.caption.bold())
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(.regularMaterial, in: .capsule)
                    }
                }
            }
            .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
            .frame(height: 220)
            .padding(10)
            .zanzanSketchCard(tint: .zanzanSun)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .accessibilityLabel("本月支出分类构成")
        }
    }

    private func rankingSection(
        _ title: LocalizedStringKey,
        items: [MonthlyStats.CategoryStat],
        total: Int,
        tint: Color
    ) -> some View {
        Section(title) {
            if items.isEmpty {
                Text("暂无数据")
                    .foregroundStyle(.secondary)
            }
            ForEach(items, id: \.category.uuid) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label {
                            Text(item.category.name)
                        } icon: {
                            CategoryIconView(category: item.category, size: 24)
                        }
                        Spacer()
                        Text(formatAmount(item.totalMinorUnits))
                            .monospacedDigit()
                    }
                    ProgressView(value: total > 0 ? Double(max(item.totalMinorUnits, 0)) / Double(total) : 0)
                        .tint(tint)
                    if !item.children.isEmpty {
                        Text(item.children.map { "\($0.category.name) \(formatAmount($0.amountMinorUnits))" }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .zanzanSketchCard(tint: tint)
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                .listRowBackground(Color.clear)
            }
        }
    }

    private func shiftMonth(_ delta: Int) {
        guard let shifted = Calendar.current.date(byAdding: .month, value: delta, to: monthAnchor) else { return }
        if reduceMotion {
            monthAnchor = shifted
        } else {
            withAnimation(.snappy) {
                monthAnchor = shifted
            }
        }
    }
}
