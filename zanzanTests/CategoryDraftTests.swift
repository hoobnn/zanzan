import Foundation
import Testing
@testable import zanzan

@MainActor
struct CategoryDraftTests {
    @Test func 合法草稿通过并归一化() throws {
        var draft = CategoryDraft()
        draft.name = "  奶茶 "
        draft.kind = .expense
        draft.iconPrimary = " cup.and.saucer "
        let v = try draft.validated()
        #expect(v.name == "奶茶")
        #expect(v.kind == .expense)
        #expect(v.iconPrimary == "cup.and.saucer")
        #expect(v.parentID == nil)
    }

    @Test func 空名被拒() {
        var draft = CategoryDraft()
        draft.name = "  "
        #expect(throws: CategoryDraftError.self) { _ = try draft.validated() }
    }

    @Test func 转账方向被拒() {
        var draft = CategoryDraft()
        draft.name = "非法"
        draft.kind = .transfer
        #expect(throws: CategoryDraftError.self) { _ = try draft.validated() }
    }

    @Test func 图标为空回退默认() throws {
        var draft = CategoryDraft()
        draft.name = "杂项"
        let v = try draft.validated()
        #expect(v.iconPrimary == "tag")
    }
}
