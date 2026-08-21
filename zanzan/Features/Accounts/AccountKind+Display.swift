import Foundation

/// 账户大类展示文案与默认图标（UI 层文案，不入 Core）。
extension AccountKind {
    var displayName: String {
        switch self {
        case .fund: ZanzanLocalization.string( "资金")
        case .credit: ZanzanLocalization.string( "信用")
        case .prepaid: ZanzanLocalization.string( "充值")
        case .investment: ZanzanLocalization.string( "理财")
        case .receivable: ZanzanLocalization.string( "应收")
        case .payable: ZanzanLocalization.string( "应付")
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
