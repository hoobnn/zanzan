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

    @Test func 名称恰达上限通过() throws {
        var draft = CategoryDraft()
        draft.name = String(repeating: "名", count: 100)
        #expect(try draft.validated().name.count == 100)
    }

    @Test func 名称超上限拒绝() {
        var draft = CategoryDraft()
        draft.name = String(repeating: "名", count: 101)
        #expect(throws: CategoryDraftError.nameTooLong) { _ = try draft.validated() }
    }
}
