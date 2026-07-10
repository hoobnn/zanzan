import Foundation

/// 图标四件套的值类型描述符（数据库设计文档 §2/§6）。
/// 各表以摊平的四列落库（iconKindRawValue/iconPrimary/iconSecondary/iconIndex），
/// 本类型供展示层组装；Kind 按能力而非素材目录定义。
struct IconDescriptor: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case symbol // SF Symbol：primary = systemName
        case asset  // 内置素材：primary = 素材组、secondary = 素材名、index 备用序号
        case emoji  // primary = emoji 字符
    }

    var kind: Kind
    var primary: String = ""
    var secondary: String = ""
    var index: Int = 0
}
