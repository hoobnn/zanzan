import SwiftUI

struct RecentlyDeletedRow: View {
    let title: String
    let detail: String
    let deletedAt: Date
    let systemImage: String
    let accessibilityIdentifier: String
    var isRestoreEnabled = true
    let restore: () -> Void

    private var buttonTitle: LocalizedStringKey {
        isRestoreEnabled ? "恢复" : "需升级"
    }

    var body: some View {
        HStack(spacing: ZanzanStyle.compactRowSpacing) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)

                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(
                        "删除于 \(ZanzanLocalization.formatted(deletedAt, date: .abbreviated, time: .shortened))"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                    .frame(
                        width: ZanzanStyle.compactRowIconSize,
                        height: ZanzanStyle.compactRowIconSize
                    )
                    .background(Color.accentColor.opacity(0.18), in: .rect(cornerRadius: 9))
            }

            Spacer(minLength: 0)

            Button(
                buttonTitle,
                systemImage: isRestoreEnabled ? "arrow.uturn.backward" : "arrow.up.circle",
                action: restore
            )
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
                .disabled(!isRestoreEnabled)
                .accessibilityLabel(
                    isRestoreEnabled
                        ? Text("恢复 \(title)")
                        : Text("\(title) 需要升级 App 后恢复")
                )
                .accessibilityIdentifier(accessibilityIdentifier)
        }
    }
}
