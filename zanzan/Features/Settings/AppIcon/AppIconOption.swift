import Foundation

nonisolated enum AppIconOption: String, CaseIterable, Identifiable, Sendable {
    case emerald
    case ivory
    case midnight

    var id: String { rawValue }

    var alternateIconName: String? {
        switch self {
        case .emerald: nil
        case .ivory: "AppIconIvory"
        case .midnight: "AppIconMidnight"
        }
    }

    var title: String {
        switch self {
        case .emerald: ZanzanLocalization.string( "翡翠")
        case .ivory: ZanzanLocalization.string( "象牙白")
        case .midnight: ZanzanLocalization.string( "深墨")
        }
    }

    var detail: String {
        switch self {
        case .emerald: ZanzanLocalization.string( "浅色与深色随系统外观切换")
        case .ivory: ZanzanLocalization.string( "始终使用明亮的象牙白背景")
        case .midnight: ZanzanLocalization.string( "始终使用沉稳的深墨色背景")
        }
    }

    var previewAssetName: String {
        switch self {
        case .emerald: "AppIconPreview"
        case .ivory: "AppIconIvoryPreview"
        case .midnight: "AppIconMidnightPreview"
        }
    }

    init(alternateIconName: String?) {
        self = Self.allCases.first { $0.alternateIconName == alternateIconName } ?? .emerald
    }
}
