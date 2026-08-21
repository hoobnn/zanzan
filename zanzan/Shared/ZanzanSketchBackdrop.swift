import SwiftUI

/// 低对比水彩色块，只做内容背景，不承载业务含义。
struct ZanzanSketchBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            let washOpacity = colorScheme == .dark ? 0.05 : 0.075
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: size.width * 0.76,
                        y: size.height * 0.06,
                        width: size.width * 0.34,
                        height: size.height * 0.11
                    )
                ),
                with: .color(.zanzanCoral.opacity(washOpacity))
            )
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: -size.width * 0.12,
                        y: size.height * 0.38,
                        width: size.width * 0.34,
                        height: size.height * 0.13
                    )
                ),
                with: .color(.zanzanMint.opacity(washOpacity))
            )
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: size.width * 0.72,
                        y: size.height * 0.84,
                        width: size.width * 0.38,
                        height: size.height * 0.12
                    )
                ),
                with: .color(.zanzanSun.opacity(washOpacity))
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
