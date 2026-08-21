import Foundation

enum ZanzanLocalization {
    private final class BundleToken: NSObject {}

    nonisolated static var currentLanguage: ZanzanAppLanguage {
        let rawValue = UserDefaults.standard.string(forKey: ZanzanAppLanguage.storageKey)
        return rawValue.flatMap(ZanzanAppLanguage.init(rawValue:)) ?? .simplifiedChinese
    }

    nonisolated static func string(
        _ resource: String.LocalizationValue,
        language: ZanzanAppLanguage? = nil
    ) -> String {
        let language = language ?? currentLanguage
        let appBundle = Bundle(for: BundleToken.self)
        let localizationBundle = appBundle
            .url(forResource: language.rawValue, withExtension: "lproj")
            .flatMap(Bundle.init(url:))
            ?? appBundle

        return String(
            localized: resource,
            bundle: localizationBundle,
            locale: language.locale
        )
    }

    nonisolated static func formatted(
        _ date: Date,
        date dateStyle: Date.FormatStyle.DateStyle,
        time timeStyle: Date.FormatStyle.TimeStyle,
        language: ZanzanAppLanguage? = nil
    ) -> String {
        date.formatted(
            Date.FormatStyle(
                date: dateStyle,
                time: timeStyle,
                locale: (language ?? currentLanguage).locale
            )
        )
    }

    nonisolated static func formatted(
        _ date: Date,
        format: Date.FormatStyle,
        language: ZanzanAppLanguage? = nil
    ) -> String {
        date.formatted(format.locale((language ?? currentLanguage).locale))
    }
}
