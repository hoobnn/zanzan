import SwiftUI

/// 记账页自定义计算键盘：3×4 数字区 + 右列运算符与「完成」高键。
struct RecordKeypadView: View {
    @Binding var expression: AmountExpression
    let onFinish: () -> Void

    private static let spacing: CGFloat = 10
    private static let keyHeight: CGFloat = 58

    var body: some View {
        GeometryReader { proxy in
            let keyWidth = (proxy.size.width - Self.spacing * 3) / 4
            HStack(alignment: .top, spacing: Self.spacing) {
                digitBlock(keyWidth: keyWidth)
                VStack(spacing: Self.spacing) {
                    operatorKey(primary: "+", secondary: "×", width: keyWidth)
                    operatorKey(primary: "-", secondary: "÷", width: keyWidth)
                    finishKey(width: keyWidth)
                }
            }
        }
        .frame(height: Self.keyHeight * 4 + Self.spacing * 3)
    }

    private func digitBlock(keyWidth: CGFloat) -> some View {
        Grid(horizontalSpacing: Self.spacing, verticalSpacing: Self.spacing) {
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
                .foregroundStyle(.primary)
                .frame(width: width, height: Self.keyHeight)
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
                .frame(width: width, height: Self.keyHeight)
                .background(keyShape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("退格")
    }

    private func operatorKey(primary: Character, secondary: Character, width: CGFloat) -> some View {
        Button {
            expression.tapOperator(primary: primary, secondary: secondary)
        } label: {
            Text(verbatim: "\(primary) \(secondary)")
                .font(.title3.weight(.medium))
                .foregroundStyle(.primary)
                .frame(width: width, height: Self.keyHeight)
                .background(keyShape)
        }
        .buttonStyle(.plain)
    }

    private func finishKey(width: CGFloat) -> some View {
        Button(action: onFinish) {
            Text("完成")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: width, height: Self.keyHeight * 2 + Self.spacing)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color.zanzanAccent))
        }
        .buttonStyle(.plain)
    }

    private var keyShape: some View {
        RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground))
    }
}

#Preview {
    @Previewable @State var expression = AmountExpression()
    RecordKeypadView(expression: $expression) {}
        .padding(12)
        .background(Color(.systemGroupedBackground))
}
