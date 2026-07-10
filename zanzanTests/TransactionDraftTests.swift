import Foundation
import Testing
@testable import zanzan

@MainActor
struct TransactionDraftTests {
    private func transferDraft() -> TransactionDraft {
        var draft = TransactionDraft()
        draft.kind = .transfer
        draft.amountString = "100"
        draft.accountUUID = UUID()
        draft.targetAccountUUID = UUID()
        return draft
    }

    @Test func 负手续费拒绝() {
        var draft = transferDraft()
        draft.feeString = "-1"
        #expect(throws: TransactionDraftError.invalidFee) { _ = try draft.validated() }
    }

    @Test func 溢出手续费拒绝() {
        var draft = transferDraft()
        draft.feeString = "92233720368547758.08" // 旧实现会环绕成 Int.min 负 fee
        #expect(throws: TransactionDraftError.invalidFee) { _ = try draft.validated() }
    }

    @Test func 合法手续费通过() throws {
        var draft = transferDraft()
        draft.feeString = "0.50"
        #expect(try draft.validated().feeMinorUnits == 50)
    }

    @Test func 非法汇率拒绝() {
        for bad in ["1,2", "1e3", "6.89abc", "0", "-1"] {
            var draft = transferDraft()
            draft.fxRateString = bad
            #expect(throws: TransactionDraftError.invalidFxRate) { _ = try draft.validated() }
        }
    }

    @Test func 合法汇率通过() throws {
        var draft = transferDraft()
        draft.fxRateString = "6.8912"
        #expect(try draft.validated().fxRateToBase == Decimal(string: "6.8912"))
    }
}
