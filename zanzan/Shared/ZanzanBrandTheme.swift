import SwiftUI

nonisolated enum ZanzanBrandTheme: String, CaseIterable, Identifiable {
    case ivory
    case emerald

    static let storageKey = "zanzan.brandTheme"
    static let defaultValue: Self = .ivory

    var id: Self { self }

    static func resolve(_ rawValue: String?) -> Self {
        Self(rawValue: rawValue ?? "") ?? defaultValue
    }

    var title: String.LocalizationValue {
        switch self {
        case .ivory: "象牙白"
        case .emerald: "翡翠雾"
        }
    }

    var subtitle: String.LocalizationValue {
        switch self {
        case .ivory: "白色玻璃表面作为默认主题，深色模式继续跟随系统。"
        case .emerald: "轻柔的翡翠雾只调整背景氛围，收支颜色仍按业务语义显示。"
        }
    }

    func pageWash(for colorScheme: ColorScheme) -> Color {
        switch self {
        case .ivory:
            colorScheme == .dark ? .clear : .white
        case .emerald:
            Color(red: 0.66, green: 0.88, blue: 0.80)
        }
    }

    func previewColor(for colorScheme: ColorScheme) -> Color {
        switch self {
        case .ivory:
            colorScheme == .dark ? Color(white: 0.78) : .white
        case .emerald:
            colorScheme == .dark
                ? Color(red: 0.22, green: 0.42, blue: 0.35)
                : Color(red: 0.76, green: 0.92, blue: 0.86)
        }
    }
}
