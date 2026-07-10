import SwiftUI

/// 流水行：彩色圆底图标 + 标题/时间 + 金额/账户；报销单附状态标签。
struct TransactionRowView: View {
    let transaction: StoredTransaction

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(iconBackground)
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: iconName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let reimbursementText {
                    Text(reimbursementText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(.systemGray6)))
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(amountText)
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                if let accountText {
                    Text(accountText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        switch transaction.kind {
        case .transfer:
            String(localized: "转账")
        case .expense, .income:
            switch transaction.settlementKind {
            case .reimbursement: String(localized: "报销入账")
            case .refund: String(localized: "退款入账")
            case nil: transaction.category?.name ?? String(localized: "未分类")
            }
        case nil:
            String(localized: "未知类型")
        }
    }

    private var subtitle: String {
        let time = transaction.occurredAt.formatted(date: .omitted, time: .shortened)
        // 到账单点出关联分类；普通流水点出备注
        let detail = transaction.settlementKind != nil
            ? transaction.category?.name
            : (transaction.note.isEmpty ? nil : transaction.note)
        guard let detail else { return time }
        return "\(time) · \(detail)"
    }

    private var iconName: String {
        switch transaction.kind {
        case .transfer:
            "arrow.left.arrow.right"
        case .expense, .income:
            if let symbol = transaction.category?.iconPrimary, !symbol.isEmpty {
                symbol
            } else {
                "circle.dashed"
            }
        case nil:
            "questionmark"
        }
    }

    private var iconBackground: Color {
        switch transaction.kind {
        case .income: .zanzanIncome
        case .expense, .transfer: .zanzanWarm
        case nil: Color(.systemGray3)
        }
    }

    private var amountText: String {
        let showsPlus = transaction.kind == .income && transaction.settlementKind == nil
        return formatAmount(transaction.amountMinorUnits, withSign: showsPlus)
    }

    private var accountText: String? {
        switch transaction.kind {
        case .transfer:
            "\(transaction.account?.name ?? String(localized: "未知账户")) → \(transaction.targetAccount?.name ?? String(localized: "未知账户"))"
        case .expense, .income, nil:
            transaction.account?.name
        }
    }

    private var reimbursementText: String? {
        switch transaction.reimbursementStatus {
        case .waiting: String(localized: "待报销")
        case .settled: String(localized: "已报销")
        case nil: nil
        }
    }
}
