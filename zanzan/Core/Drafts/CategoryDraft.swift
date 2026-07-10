import Foundation

/// 分类表单草稿——入口校验 + 归一化（设计文档 5.3）。
/// 方向仅 expense/income 合法；parentID 存在性/层级校验属命令层（需查库）。
struct CategoryDraft {
    var name: String = ""
    var kind: TransactionKind = .expense
    var parentID: UUID? = nil
    var iconPrimary: String = ""

    struct Validated {
        let name: String
        let kind: TransactionKind
        let parentID: UUID?
        let iconPrimary: String
    }

    func validated() throws -> Validated {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CategoryDraftError.emptyName }
        guard name.count <= DraftLimits.maxNameLength else { throw CategoryDraftError.nameTooLong }
        guard kind != .transfer else { throw CategoryDraftError.invalidKind }
        let icon = iconPrimary.trimmingCharacters(in: .whitespaces)
        return Validated(
            name: name,
            kind: kind,
            parentID: parentID,
            iconPrimary: icon.isEmpty ? "tag" : icon
        )
    }
}

extension CategoryDraft {
    /// 编辑表单回填。
    init(category: Category) {
        self.init()
        name = category.name
        kind = category.kind ?? .expense
        parentID = category.parentID
        iconPrimary = category.iconPrimary
    }
}

enum CategoryDraftError: LocalizedError {
    case emptyName
    case nameTooLong
    case invalidKind

    var errorDescription: String? {
        switch self {
        case .emptyName: String(localized: "分类名不能为空")
        case .nameTooLong: String(localized: "分类名不能超过 \(DraftLimits.maxNameLength) 字")
        case .invalidKind: String(localized: "分类方向只能是支出或收入")
        }
    }
}
