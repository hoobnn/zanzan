import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct FxRateProviderTests {
    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    /// 直接落一笔带币种/汇率的流水作为快照来源
    @discardableResult
    private func insertTransaction(
        _ context: ModelContext,
        currency: String,
        rate: Decimal?,
        occurredAt: Date,
        isSoftDeleted: Bool = false
    ) throws -> Transaction {
        let tx = Transaction(kind: .expense, amountMinorUnits: 100, occurredAt: occurredAt, ledgerID: UUID())
        tx.currencyCode = currency
        tx.fxRateToBase = rate
        tx.isSoftDeleted = isSoftDeleted
        context.insert(tx)
        try context.save()
        return tx
    }

    @Test func 最近一笔流水快照优先() throws {
        let context = try makeContext()
        try insertTransaction(context, currency: "USD", rate: Decimal(string: "7.10")!, occurredAt: .now.addingTimeInterval(-3_600))
        try insertTransaction(context, currency: "USD", rate: Decimal(string: "7.25")!, occurredAt: .now)
        let rate = try FxRateProvider(context: context).rate(for: "USD")
        #expect(rate == Decimal(string: "7.25"))
    }

    @Test func 软删流水不作为快照() throws {
        let context = try makeContext()
        try insertTransaction(context, currency: "USD", rate: Decimal(string: "7.10")!, occurredAt: .now.addingTimeInterval(-3_600))
        try insertTransaction(context, currency: "USD", rate: Decimal(string: "9.99")!, occurredAt: .now, isSoftDeleted: true)
        let rate = try FxRateProvider(context: context).rate(for: "USD")
        #expect(rate == Decimal(string: "7.10"))
    }

    @Test func 本位币汇率恒为1() throws {
        let context = try makeContext()
        let rate = try FxRateProvider(context: context).rate(for: "CNY")
        #expect(rate == 1)
    }

    @Test func 无快照返回nil() throws {
        let context = try makeContext()
        // 无汇率的同币种流水不构成快照（谓词过滤 fxRateToBase != nil）
        try insertTransaction(context, currency: "USD", rate: nil, occurredAt: .now)
        let rate = try FxRateProvider(context: context).rate(for: "JPY")
        #expect(rate == nil)
        #expect(try FxRateProvider(context: context).rate(for: "USD") == nil)
    }
}
