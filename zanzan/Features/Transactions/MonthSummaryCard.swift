import SwiftUI

/// 账本页月结余卡：结余大字 + 总支出/总收入 + 页点。
struct MonthSummaryCard: View {
    let expenseMinorUnits: Int
    let incomeMinorUnits: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var balanceMinorUnits: Int {
        incomeMinorUnits - expenseMinorUnits
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text("月结余")
                Image(systemName: "arrow.left.arrow.right")
                    .font(.footnote.bold())
                    .accessibilityHidden(true)
            }
            .font(.subheadline)
            .bold()
            .foregroundStyle(.tint)
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .background(Color.zanzanSun.opacity(0.14), in: .capsule)
            Text(formatAmount(balanceMinorUnits))
                .font(.title2)
                .bold()
                .monospacedDigit()
                .foregroundStyle(
                    balanceMinorUnits == 0
                        ? Color.primary
                        : (balanceMinorUnits > 0 ? .zanzanIncome : .zanzanExpense)
                )
                .contentTransition(reduceMotion ? .identity : .numericText())
            HStack(spacing: 12) {
                labeledAmount("总支出", expenseMinorUnits, color: .zanzanExpense)
                labeledAmount("总收入", incomeMinorUnits, color: .zanzanIncome)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zanzanSketchCard(tint: .zanzanSun)
    }

    private func labeledAmount(
        _ title: LocalizedStringKey,
        _ minorUnits: Int,
        color: Color
    ) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.tertiary)
            Text(formatAmount(minorUnits))
                .foregroundStyle(color)
                .monospacedDigit()
        }
        .font(.subheadline)
    }
}

#Preview {
    MonthSummaryCard(expenseMinorUnits: 328_00, incomeMinorUnits: 8_600_00)
        .padding()
}
