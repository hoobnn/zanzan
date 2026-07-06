import Foundation

/// 关键枚举（数据库设计文档 §6）。rawValue 一律英文小驼峰，落库串终生不改；
/// 只加值不改值。语义类枚举解析失败一律返回 nil（按「未知」处理，禁回写兜底）。

enum TransactionKind: String, Codable, CaseIterable, Sendable {
    case expense, income, transfer
}

enum AccountKind: String, Codable, CaseIterable, Sendable {
    case fund, credit, prepaid, investment, receivable, payable
}

enum TransactionSourceKind: String, Codable, CaseIterable, Sendable {
    case manual, csvImport, recurring, voice, installment, adjustment
}

enum TransactionLinkKind: String, Codable, CaseIterable, Sendable {
    case reimbursement, refund
}

enum ReimbursementStatus: String, Codable, CaseIterable, Sendable {
    case waiting, settled
}

enum RecurrenceFrequency: String, Codable, CaseIterable, Sendable {
    case daily, weekly, monthly
}

enum InstallmentPlanKind: String, Codable, CaseIterable, Sendable {
    case purchase, statement, loan
}

enum AmortizationKind: String, Codable, CaseIterable, Sendable {
    case annuity, linearPrincipal, interestOnly, flatFee, custom
}

enum InstallmentPlanStatus: String, Codable, CaseIterable, Sendable {
    case active, completed, settledEarly
}

enum InstallmentPeriodStatus: String, Codable, CaseIterable, Sendable {
    case pending, settled, cancelled
}
