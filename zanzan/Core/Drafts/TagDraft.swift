import Foundation

/// 标签表单草稿——入口校验 + 归一化（设计文档 5.6）。
/// 同库重名校验属命令层（需查库），见 TagService。
struct TagDraft {
    var name: String = ""
    var colorID: String = "blue"
    /// nil = 全局标签
    var ledgerID: UUID? = nil

    struct Validated {
        let name: String
        let colorID: String
        let ledgerID: UUID?
    }

    func validated() throws -> Validated {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TagDraftError.emptyName }
        guard name.count <= DraftLimits.maxNameLength else { throw TagDraftError.nameTooLong }
        let color = colorID.trimmingCharacters(in: .whitespaces)
        return Validated(
            name: name,
            colorID: color.isEmpty ? "blue" : color,
            ledgerID: ledgerID
        )
    }
}

extension TagDraft {
    /// 编辑表单回填。
    init(tag: Tag) {
        self.init()
        name = tag.name
        colorID = tag.colorID
        ledgerID = tag.ledgerID
    }
}

enum TagDraftError: LocalizedError {
    case emptyName
    case nameTooLong

    var errorDescription: String? {
        switch self {
        case .emptyName: String(localized: "标签名不能为空")
        case .nameTooLong: String(localized: "标签名不能超过 \(DraftLimits.maxNameLength) 字")
        }
    }
}
