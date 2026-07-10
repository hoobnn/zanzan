import Foundation
import Testing
@testable import zanzan

@MainActor
struct LedgerDraftTests {
    @Test func 合法草稿通过并trim归一化() throws {
        var draft = LedgerDraft()
        draft.name = "  日常账本  "
        let v = try draft.validated()
        #expect(v.name == "日常账本")
        #expect(v.colorID == "blue")
    }

    @Test func 空名被拒() {
        var draft = LedgerDraft()
        draft.name = "   "
        #expect(throws: LedgerDraftError.emptyName) { _ = try draft.validated() }
    }

    @Test func 名称恰达上限通过() throws {
        var draft = LedgerDraft()
        draft.name = String(repeating: "名", count: 100)
        #expect(try draft.validated().name.count == 100)
    }

    @Test func 名称超上限拒绝() {
        var draft = LedgerDraft()
        draft.name = String(repeating: "名", count: 101)
        #expect(throws: LedgerDraftError.nameTooLong) { _ = try draft.validated() }
    }
}
