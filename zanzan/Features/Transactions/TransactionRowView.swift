import SwiftUI

/// 流水行：彩色圆底图标 + 标题/时间 + 金额/账户；报销单附状态标签。
struct TransactionRowView: View {
    let transaction: Transaction
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ZanzanStyle.transactionRowFrameStorageKey)
    private var showsFrame = ZanzanStyle.defaultShowsTransactionRowFrame

    var body: some View {
        HStack(spacing: 8) {
            leadingIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let reimbursementText {
                    Text(reimbursementText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.thinMaterial, in: .capsule)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(amountText)
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(amountColor)
                if let accountText {
                    Text(accountText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, showsFrame ? 8 : 4)
        .padding(.vertical, showsFrame ? 2 : 0)
        .frame(minHeight: showsFrame ? 48 : 44)
        .background {
            if showsFrame {
                RoundedRectangle(cornerRadius: ZanzanStyle.sketchCompactRadius)
                    .fill(.thinMaterial)
            }
        }
        .overlay {
            if showsFrame {
                RoundedRectangle(cornerRadius: ZanzanStyle.sketchCompactRadius)
                    .strokeBorder(
                        iconBackground.opacity(colorScheme == .dark ? 0.24 : 0.30),
                        lineWidth: 0.8
                    )
            }
        }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        switch transaction.kind {
        case .expense, .income:
            if let category = transaction.category {
                Circle()
                    .fill(iconBackground.opacity(0.16))
                    .frame(width: 36, height: 36)
                    .overlay {
                        CategoryIconView(category: category, size: 30)
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(
                                iconBackground.opacity(0.30),
                                lineWidth: 0.8
                            )
                    }
                    .accessibilityHidden(true)
            } else {
                fallbackIcon("circle.dashed")
            }
        case .transfer:
            fallbackIcon("arrow.left.arrow.right")
        case nil:
            fallbackIcon("questionmark")
        }
    }

    private func fallbackIcon(_ systemName: String) -> some View {
        Circle()
            .fill(iconBackground)
            .frame(width: 36, height: 36)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(iconForeground)
            }
            .accessibilityHidden(true)
    }

    private var title: String {
        switch transaction.kind {
        case .transfer:
            ZanzanLocalization.string( "转账")
        case .expense, .income:
            switch transaction.settlementKind {
            case .reimbursement: ZanzanLocalization.string( "报销入账")
            case .refund: ZanzanLocalization.string( "退款入账")
            case nil: transaction.category?.name ?? ZanzanLocalization.string( "未分类")
            }
        case nil:
            ZanzanLocalization.string( "未知类型")
        }
    }

    private var subtitle: String {
        let time = ZanzanLocalization.formatted(
            transaction.occurredAt,
            date: .omitted,
            time: .shortened
        )
        // 到账单点出关联分类；普通流水点出备注
        let detail = transaction.settlementKind != nil
            ? transaction.category?.name
            : (transaction.note.isEmpty ? nil : transaction.note)
        guard let detail else { return time }
        return "\(time) · \(detail)"
    }

    private var iconBackground: Color {
        transaction.kind?.tintColor(for: colorScheme) ?? .gray.opacity(0.55)
    }

    private var iconForeground: Color {
        transaction.kind?.onTintColor(for: colorScheme) ?? .primary
    }

    private var amountColor: Color {
        transaction.kind?.tintColor(for: colorScheme) ?? .primary
    }

    private var amountText: String {
        switch transaction.kind {
        case .expense:
            formatAmount(
                -transaction.amountMinorUnits,
                currencyCode: transaction.currencyCode
            )
        case .income:
            formatAmount(
                transaction.amountMinorUnits,
                withSign: true,
                currencyCode: transaction.currencyCode
            )
        case .transfer, nil:
            formatAmount(
                transaction.amountMinorUnits,
                currencyCode: transaction.currencyCode
            )
        }
    }

    private var accountText: String? {
        switch transaction.kind {
        case .transfer:
            "\(transaction.account?.name ?? ZanzanLocalization.string( "未知账户")) → \(transaction.targetAccount?.name ?? ZanzanLocalization.string( "未知账户"))"
        case .expense, .income, nil:
            transaction.account?.name
        }
    }

    private var reimbursementText: String? {
        switch transaction.reimbursementStatus {
        case .waiting: ZanzanLocalization.string( "待报销")
        case .settled: ZanzanLocalization.string( "已报销")
        case nil: nil
        }
    }
}
