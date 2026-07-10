import Foundation

/// 账本表单草稿——入口校验 + 归一化（三层防线第一层）。
struct LedgerDraft {
    var name: String = ""
    var colorID: String = "blue"

    /// 归一化（trim）并校验；非法输入 fail fast。
    func validated() throws -> LedgerDraft {
        var draft = self
        draft.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.name.isEmpty else { throw LedgerDraftError.emptyName }
        return draft
    }
}

enum LedgerDraftError: LocalizedError {
    case emptyName

    var errorDescription: String? {
        switch self {
        case .emptyName: String(localized: "账本名不能为空")
        }
    }
}
