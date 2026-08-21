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
        for bad in ["1,2", "1e3", "6.89abc", "0", "-1", "10000"] {
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

    @Test func 位置三字段同空同有且校验坐标范围() throws {
        var draft = transferDraft()
        draft.locationName = "公司"
        #expect(throws: TransactionDraftError.invalidLocation) {
            _ = try draft.validated()
        }

        draft.locationLatitudeString = "31.2304"
        draft.locationLongitudeString = "121.4737"
        let location = try draft.validated()
        #expect(location.locationName == "公司")
        #expect(abs((location.locationLatitude ?? 0) - 31.2304) < 0.000_001)
        #expect(abs((location.locationLongitude ?? 0) - 121.4737) < 0.000_001)

        draft.locationLatitudeString = "91"
        #expect(throws: TransactionDraftError.invalidLocation) {
            _ = try draft.validated()
        }
    }

    // MARK: - DraftLimits 边界

    @Test func 备注恰达上限通过() throws {
        var draft = transferDraft()
        draft.note = String(repeating: "备", count: 500)
        #expect(try draft.validated().note.count == 500)
    }

    @Test func 备注超上限拒绝() {
        var draft = transferDraft()
        draft.note = String(repeating: "备", count: 501)
        #expect(throws: TransactionDraftError.noteTooLong) { _ = try draft.validated() }
    }

    @Test func 记账时间区间边界通过() throws {
        for ts: TimeInterval in [0, 4_102_444_799] {
            var draft = transferDraft()
            draft.occurredAt = Date(timeIntervalSince1970: ts)
            _ = try draft.validated()
        }
    }

    @Test func 记账时间越界拒绝() {
        for ts: TimeInterval in [-1, 4_102_444_800, 64_060_675_200] { // 含公元 4000 年
            var draft = transferDraft()
            draft.occurredAt = Date(timeIntervalSince1970: ts)
            #expect(throws: TransactionDraftError.occurredAtOutOfRange) { _ = try draft.validated() }
        }
    }
}
