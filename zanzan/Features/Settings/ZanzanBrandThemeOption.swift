import SwiftUI

struct ZanzanBrandThemeOption: View {
    let theme: ZanzanBrandTheme
    let isSelected: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(theme.previewColor(for: colorScheme))
                .stroke(.quaternary, lineWidth: 1)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            Text(ZanzanLocalization.string(theme.title))
                .foregroundStyle(.primary)

            Spacer(minLength: 0)

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(
            Color.primary.opacity(isSelected ? 0.055 : 0.025),
            in: .rect(cornerRadius: ZanzanStyle.compactRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ZanzanStyle.compactRadius)
                .stroke(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                        lineWidth: isSelected ? 1.5 : 1)
        }
        .contentShape(.rect)
    }
}
