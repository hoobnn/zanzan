import SwiftUI

/// 记账页自定义计算键盘：3×4 数字区 + 右列运算符与「完成」高键。
struct RecordKeypadView: View {
    @Binding var expression: AmountExpression
    let kind: TransactionKind
    let onFinish: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var spacing: CGFloat { 6 }
    private var keyHeight: CGFloat { verticalSizeClass == .compact ? 44 : 50 }

    var body: some View {
        GeometryReader { proxy in
            let keyWidth = max(0, (proxy.size.width - spacing * 3) / 4)
            HStack(alignment: .top, spacing: spacing) {
                digitBlock(keyWidth: keyWidth)
                VStack(spacing: spacing) {
                    operatorKey(primary: "+", secondary: "×", width: keyWidth)
                    operatorKey(primary: "-", secondary: "÷", width: keyWidth)
                    finishKey(width: keyWidth)
                }
            }
        }
        .frame(height: keyHeight * 4 + spacing * 3)
    }

    private func digitBlock(keyWidth: CGFloat) -> some View {
        Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
            GridRow { digitKey("1", width: keyWidth); digitKey("2", width: keyWidth); digitKey("3", width: keyWidth) }
            GridRow { digitKey("4", width: keyWidth); digitKey("5", width: keyWidth); digitKey("6", width: keyWidth) }
            GridRow { digitKey("7", width: keyWidth); digitKey("8", width: keyWidth); digitKey("9", width: keyWidth) }
            GridRow { digitKey(".", width: keyWidth); digitKey("0", width: keyWidth); backspaceKey(width: keyWidth) }
        }
    }

    private func digitKey(_ digit: Character, width: CGFloat) -> some View {
        Button {
            expression.tapDigit(digit)
        } label: {
            Text(String(digit))
                .font(.title2.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(.primary)
                .frame(width: width, height: keyHeight)
                .background(keyShape)
        }
        .buttonStyle(.plain)
    }

    private func backspaceKey(width: CGFloat) -> some View {
        Button {
            expression.tapBackspace()
        } label: {
            Image(systemName: "delete.left.fill")
                .font(.title3)
                .foregroundStyle(.primary)
                .frame(width: width, height: keyHeight)
                .background(keyShape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("退格")
    }

    private func operatorKey(primary: Character, secondary: Character, width: CGFloat) -> some View {
        Button {
            expression.tapOperator(primary: primary, secondary: secondary)
        } label: {
            VStack(spacing: -2) {
                Text(String(primary))
                    .font(.title3.weight(.semibold))
                Text(String(secondary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .frame(width: width, height: keyHeight)
            .background(operatorShape)
        }
        .buttonStyle(.plain)
    }

    private func finishKey(width: CGFloat) -> some View {
        Button(action: onFinish) {
            Text("完成")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(kind.onTintColor(for: colorScheme))
                .frame(width: width, height: keyHeight * 2 + spacing)
                .background(
                    kind.prominentGradient(for: colorScheme),
                    in: .rect(cornerRadius: ZanzanStyle.sketchCompactRadius)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("recordFinishButton")
    }

    private var keyShape: some View {
        RoundedRectangle(cornerRadius: ZanzanStyle.sketchCompactRadius)
            .fill(.thinMaterial)
    }

    private var operatorShape: some View {
        RoundedRectangle(cornerRadius: ZanzanStyle.sketchCompactRadius)
            .fill(kind.tintColor(for: colorScheme).opacity(colorScheme == .dark ? 0.14 : 0.08))
    }
}

#Preview {
    @Previewable @State var expression = AmountExpression()
    RecordKeypadView(expression: $expression, kind: .expense) {}
        .padding(12)
        .zanzanSketchPageBackground()
}
