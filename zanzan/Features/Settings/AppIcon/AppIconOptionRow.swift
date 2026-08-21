import SwiftUI

struct AppIconOptionRow: View {
    let option: AppIconOption
    let isSelected: Bool
    let isChanging: Bool

    var body: some View {
        HStack(spacing: ZanzanStyle.compactRowSpacing) {
            Image(option.previewAssetName)
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .clipShape(.rect(cornerRadius: 11))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(option.title)
                    .font(.headline)

                Text(option.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isChanging {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在切换")
            } else if isSelected {
                Label("已选择", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(.rect)
    }
}

#Preview {
    List {
        AppIconOptionRow(option: .emerald, isSelected: true, isChanging: false)
        AppIconOptionRow(option: .ivory, isSelected: false, isChanging: false)
        AppIconOptionRow(option: .midnight, isSelected: false, isChanging: true)
    }
}
