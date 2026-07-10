import Foundation
import Testing
@testable import zanzan

@MainActor
struct AccountDraftTests {
    private func makeDraft() -> AccountDraft {
        var draft = AccountDraft()
        draft.name = "招行卡"
        return draft
    }

    @Test func 合法草稿通过并归一化() throws {
        var draft = makeDraft()
        draft.name = "  招行卡  "
        draft.subtitle = " 工资卡 "
        let v = try draft.validated()
        #expect(v.name == "招行卡")
        #expect(v.subtitle == "工资卡")
        #expect(v.currencyCode == "CNY")
    }

    @Test func 空名被拒() {
        var draft = makeDraft()
        draft.name = "   "
        #expect(throws: AccountDraftError.emptyName) { _ = try draft.validated() }
    }

    @Test func 名称恰达上限通过() throws {
        var draft = makeDraft()
        draft.name = String(repeating: "名", count: 100)
        #expect(try draft.validated().name.count == 100)
    }

    @Test func 名称超上限拒绝() {
        var draft = makeDraft()
        draft.name = String(repeating: "名", count: 101)
        #expect(throws: AccountDraftError.nameTooLong) { _ = try draft.validated() }
    }

    @Test func 副标题恰达上限通过() throws {
        var draft = makeDraft()
        draft.subtitle = String(repeating: "副", count: 100)
        #expect(try draft.validated().subtitle.count == 100)
    }

    @Test func 副标题超上限拒绝() {
        var draft = makeDraft()
        draft.subtitle = String(repeating: "副", count: 101)
        #expect(throws: AccountDraftError.subtitleTooLong) { _ = try draft.validated() }
    }
}
