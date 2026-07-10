import SwiftData
import SwiftUI

/// 记账页功能胶囊行：账户选择可用；报销/优惠/图片/标签/设置为占位（后续切片接功能）。
struct RecordChipsRow: View {
    let accounts: [Account]
    @Binding var selectedAccountUUID: UUID?

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    accountChip
                    // ponytail: 以下入口预留，仅占版式
                    chipLabel(String(localized: "报销"), symbol: "circle", tint: .secondary)
                    chipLabel(String(localized: "优惠"), symbol: "gift.fill", tint: .zanzanIncome)
                    chipLabel(String(localized: "图片"), symbol: "photo.fill", tint: .zanzanWarm)
                    chipLabel(String(localized: "标签"), symbol: "tag.fill", tint: .teal)
                }
                .padding(.vertical, 6) // 给阴影留出裁切空间
            }
            .scrollIndicators(.hidden)
            Image(systemName: "gearshape.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
                .accessibilityHidden(true)
        }
    }

    private var accountChip: some View {
        Menu {
            ForEach(accounts) { account in
                Button(account.name) { selectedAccountUUID = account.uuid }
            }
        } label: {
            chipLabel(selectedAccountName ?? String(localized: "选择账户"), symbol: "creditcard.fill", tint: .zanzanWarm)
        }
        .accessibilityLabel(Text("选择账户"))
    }

    private var selectedAccountName: String? {
        accounts.first { $0.uuid == selectedAccountUUID }?.name
    }

    private func chipLabel(_ title: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint)
            Text(title)
                .font(.footnote)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
        )
    }
}
