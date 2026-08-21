import SwiftUI

extension TransactionKind {
    var displayName: String {
        switch self {
        case .expense: ZanzanLocalization.string( "支出")
        case .income: ZanzanLocalization.string( "收入")
        case .transfer: ZanzanLocalization.string( "转账")
        }
    }

    func tintColor(for colorScheme: ColorScheme) -> Color {
        switch (self, colorScheme) {
        case (.expense, .light):
            Color(red: 0.72, green: 0.10, blue: 0.18)
        case (.expense, .dark):
            Color(red: 0.96, green: 0.40, blue: 0.46)
        case (.income, .light):
            Color(red: 0.02, green: 0.47, blue: 0.34)
        case (.income, .dark):
            Color(red: 0.28, green: 0.78, blue: 0.60)
        case (.transfer, .light):
            Color(red: 0.76, green: 0.52, blue: 0.10)
        case (.transfer, .dark):
            Color(red: 0.96, green: 0.72, blue: 0.30)
        @unknown default:
            tintColor(for: .light)
        }
    }

    func onTintColor(for colorScheme: ColorScheme) -> Color {
        switch (self, colorScheme) {
        case (.expense, .light), (.income, .light):
            .white
        default:
            .black
        }
    }

    func prominentGradient(for colorScheme: ColorScheme) -> LinearGradient {
        let tint = tintColor(for: colorScheme)
        return LinearGradient(
            colors: [tint.opacity(0.82), tint],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
