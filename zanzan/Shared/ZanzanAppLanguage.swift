import Foundation

enum ZanzanAppLanguage: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    nonisolated static let storageKey = "zanzan.appLanguage"

    var id: Self { self }
    nonisolated var locale: Locale { Locale(identifier: rawValue) }

    var title: String.LocalizationValue {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }
}
