import Foundation

extension TransactionKind {
    var displayName: String {
        switch self {
        case .expense: String(localized: "支出")
        case .income: String(localized: "收入")
        case .transfer: String(localized: "转账")
        }
    }
}
