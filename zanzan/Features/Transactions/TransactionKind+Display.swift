import Foundation

extension TransactionKind {
    var displayName: String {
        switch self {
        case .expense: "支出"
        case .income: "收入"
        case .transfer: "转账"
        }
    }
}
