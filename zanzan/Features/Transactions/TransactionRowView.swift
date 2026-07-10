import SwiftUI

/// 流水行：分类图标 + 标题/备注 + 带符号金额。语义未知流水按「未知」降级展示。
struct TransactionRowView: View {
    let transaction: StoredTransaction

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading) {
                Text(title)
                if !transaction.note.isEmpty {
                    Text(transaction.note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(amountText)
                .foregroundStyle(amountColor)
                .monospacedDigit()
        }
    }

    private var title: String {
        switch transaction.kind {
        case .transfer:
            "\(transaction.account?.name ?? String(localized: "未知账户")) → \(transaction.targetAccount?.name ?? String(localized: "未知账户"))"
        case .expense, .income:
            transaction.category?.name ?? String(localized: "未分类")
        case nil:
            String(localized: "未知类型")
        }
    }

    private var iconName: String {
        switch transaction.kind {
        case .transfer:
            "arrow.left.arrow.right.circle"
        case .expense, .income:
            if let symbol = transaction.category?.iconPrimary, !symbol.isEmpty {
                symbol
            } else {
                "circle.dashed"
            }
        case nil:
            "questionmark.circle"
        }
    }

    private var amountText: String {
        switch transaction.kind {
        case .transfer: formatAmount(transaction.amountMinorUnits)
        default: formatAmount(transaction.signedMinorUnits, withSign: true)
        }
    }

    private var amountColor: Color {
        switch transaction.kind {
        case .income: .green
        case .transfer: .secondary
        case .expense, nil: .primary
        }
    }
}
