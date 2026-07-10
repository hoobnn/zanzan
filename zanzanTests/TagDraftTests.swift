import Foundation
import Testing
@testable import zanzan

@MainActor
struct TagDraftTests {
    @Test func 名称去空白后通过() throws {
        var draft = TagDraft()
        draft.name = "  旅行 \n"
        let v = try draft.validated()
        #expect(v.name == "旅行")
    }

    @Test func 空名被拒() {
        var draft = TagDraft()
        draft.name = "   \n"
        #expect(throws: TagDraftError.emptyName) {
            try draft.validated()
        }
    }

    @Test func 颜色空串回落默认蓝() throws {
        var draft = TagDraft()
        draft.name = "旅行"
        draft.colorID = "  "
        let v = try draft.validated()
        #expect(v.colorID == "blue")
    }

    @Test func 账本归属原样保留() throws {
        let ledgerID = UUID()
        var draft = TagDraft()
        draft.name = "旅行"
        draft.colorID = "red"
        draft.ledgerID = ledgerID
        let v = try draft.validated()
        #expect(v.colorID == "red")
        #expect(v.ledgerID == ledgerID)
    }

    @Test func 编辑回填() {
        let tag = Tag(name: "旅行")
        tag.colorID = "green"
        tag.ledgerID = UUID()
        let draft = TagDraft(tag: tag)
        #expect(draft.name == "旅行")
        #expect(draft.colorID == "green")
        #expect(draft.ledgerID == tag.ledgerID)
    }

    @Test func 名称恰达上限通过() throws {
        var draft = TagDraft()
        draft.name = String(repeating: "名", count: 100)
        #expect(try draft.validated().name.count == 100)
    }

    @Test func 名称超上限拒绝() {
        var draft = TagDraft()
        draft.name = String(repeating: "名", count: 101)
        #expect(throws: TagDraftError.nameTooLong) { _ = try draft.validated() }
    }
}
