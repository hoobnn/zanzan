import SwiftUI

nonisolated enum ZanzanBackdropStyle: String, CaseIterable, Identifiable {
    case sketch
    case wash
    case plain

    static let storageKey = "zanzan.backdropStyle"
    static let defaultValue: Self = .sketch

    var id: Self { self }

    static func resolve(_ rawValue: String?) -> Self {
        Self(rawValue: rawValue ?? "") ?? defaultValue
    }

    var title: String.LocalizationValue {
        switch self {
        case .sketch: "彩色手绘"
        case .wash: "柔和渐变"
        case .plain: "纯净背景"
        }
    }
}
