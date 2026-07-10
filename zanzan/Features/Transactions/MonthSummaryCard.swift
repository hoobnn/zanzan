import SwiftUI

/// 账本页月结余卡：结余大字 + 总支出/总收入 + 页点。
struct MonthSummaryCard: View {
    let expenseMinorUnits: Int
    let incomeMinorUnits: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "dollarsign.circle") // 预留主题图标
                Text("月结余")
                Image(systemName: "arrow.left.arrow.right")
                    .font(.caption2.weight(.bold))
                    .accessibilityHidden(true)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.zanzanWarm)
            Text(formatAmount(incomeMinorUnits - expenseMinorUnits))
                .font(.system(size: 40, weight: .heavy))
                .monospacedDigit()
                .contentTransition(.numericText())
            HStack(spacing: 24) {
                labeledAmount("总支出", expenseMinorUnits)
                labeledAmount("总收入", incomeMinorUnits)
            }
            // ponytail: 第二页（预算卡）后续切片，先落页点视觉
            HStack(spacing: 6) {
                Circle().fill(Color(.systemGray3)).frame(width: 6, height: 6)
                Circle().fill(Color(.systemGray5)).frame(width: 6, height: 6)
            }
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
        }
        .padding(.vertical, 8)
    }

    private func labeledAmount(_ title: LocalizedStringKey, _ minorUnits: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.tertiary)
            Text(formatAmount(minorUnits)).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.subheadline)
    }
}

#Preview {
    List {
        MonthSummaryCard(expenseMinorUnits: 0, incomeMinorUnits: 1200)
    }
}
