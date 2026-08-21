import SwiftData
import SwiftUI

/// 记账页功能胶囊行：账户、报销、附件与标签。
struct RecordChipsRow: View {
    let accounts: [Account]
    let tags: [Tag]
    let showsReimbursement: Bool
    let locksReimbursement: Bool
    let onManageAttachments: () -> Void
    @Binding var selectedAccountUUID: UUID?
    @Binding var selectedTagUUIDs: Set<UUID>
    @Binding var isReimbursementMarked: Bool

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                accountChip
                if showsReimbursement {
                    Button {
                        isReimbursementMarked.toggle()
                    } label: {
                        chipLabel(
                            isReimbursementMarked ? ZanzanLocalization.string("待报销") : ZanzanLocalization.string("报销"),
                            symbol: isReimbursementMarked ? "checkmark.circle.fill" : "circle",
                            tint: isReimbursementMarked ? .zanzanIncome : .secondary
                        )
                    }
                    .disabled(locksReimbursement)
                    .accessibilityValue(isReimbursementMarked ? Text("已选择") : Text("未选择"))
                    .accessibilityAddTraits(isReimbursementMarked ? .isSelected : [])
                }
                Button(action: onManageAttachments) {
                    chipLabel(
                        ZanzanLocalization.string("图片"),
                        symbol: "photo.fill",
                        tint: .secondary
                    )
                }
                tagMenu
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private var tagMenu: some View {
        Menu {
            if tags.isEmpty {
                Text("暂无可用标签")
            }
            ForEach(tags) { tag in
                Button {
                    if !selectedTagUUIDs.insert(tag.uuid).inserted {
                        selectedTagUUIDs.remove(tag.uuid)
                    }
                } label: {
                    if selectedTagUUIDs.contains(tag.uuid) {
                        Label(tag.name, systemImage: "checkmark")
                    } else {
                        Text(tag.name)
                    }
                }
            }
        } label: {
            chipLabel(
                selectedTagUUIDs.isEmpty
                    ? ZanzanLocalization.string("标签")
                    : ZanzanLocalization.string("\(selectedTagUUIDs.count) 个标签"),
                symbol: "tag.fill",
                tint: .secondary
            )
        }
        .accessibilityLabel("选择标签")
        .accessibilityValue(
            Text(verbatim: selectedTagUUIDs.isEmpty
                 ? ZanzanLocalization.string("未选择")
                 : ZanzanLocalization.string("\(selectedTagUUIDs.count) 个标签"))
        )
    }

    private var accountChip: some View {
        Menu {
            ForEach(accounts) { account in
                Button {
                    selectedAccountUUID = account.uuid
                } label: {
                    Label {
                        Text(account.name)
                    } icon: {
                        AccountIconView(account: account, size: 22)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if let selectedAccount {
                    AccountIconView(account: selectedAccount, size: 24)
                } else {
                    Image(systemName: "creditcard.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(selectedAccount?.name ?? ZanzanLocalization.string("选择账户"))
                    .font(.footnote)
                    .foregroundStyle(Color.primary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .glassEffect(.regular.tint(Color.zanzanSky.opacity(0.08)), in: .capsule)
        }
        .accessibilityLabel(Text("选择账户"))
        .accessibilityValue(Text(verbatim: selectedAccount?.name ?? ZanzanLocalization.string("未选择")))
    }

    private var selectedAccount: Account? {
        accounts.first { $0.uuid == selectedAccountUUID }
    }

    private func chipLabel(_ title: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint)
            Text(title)
                .font(.footnote)
                .foregroundStyle(Color.primary)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .glassEffect(.regular.tint(tint.opacity(0.08)), in: .capsule)
    }
}
