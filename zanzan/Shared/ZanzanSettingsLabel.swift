import SwiftUI

struct ZanzanSettingsLabel: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
            } icon: {
                Image(systemName: systemImage)
                    .font(.subheadline.bold())
                    .foregroundStyle(.tint)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 8))
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(Color.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: .rect(cornerRadius: 12))
        .contentShape(.rect)
    }
}
