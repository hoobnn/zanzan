import Foundation

/// 账户大类展示文案与默认图标（UI 层文案，不入 Core）。
extension AccountKind {
    var displayName: String {
        switch self {
        case .fund: "资金"
        case .credit: "信用"
        case .prepaid: "充值"
        case .investment: "理财"
        case .receivable: "应收"
        case .payable: "应付"
        }
    }

    var symbolName: String {
        switch self {
        case .fund: "banknote"
        case .credit: "creditcard"
        case .prepaid: "giftcard"
        case .investment: "chart.line.uptrend.xyaxis"
        case .receivable: "tray.and.arrow.down"
        case .payable: "tray.and.arrow.up"
        }
    }
}
