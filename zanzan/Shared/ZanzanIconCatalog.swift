import Foundation
import SwiftUI
import UIKit

/// 统一解析模型中的图标四件套，并兼容已经落库的 SF Symbol 键。
enum ZanzanIconCatalog {
    private struct Resource {
        let subdirectory: String
        let name: String
    }

    private struct IndexedResource {
        let key: String
        let url: URL
    }

    /// 内置分类的 symbol 同时承担默认分类恢复的稳定键，因此只在展示层映射实际素材。
    private static let builtInCategoryResources: [String: Resource] = [
        "fork.knife": Resource(subdirectory: "category_color/food", name: "color_food_11"),
        "sunrise": Resource(subdirectory: "category_color/food", name: "color_food_27"),
        "sun.max": Resource(subdirectory: "category_color/food", name: "color_food_34"),
        "moon": Resource(subdirectory: "category_color/food", name: "color_food_29"),
        "cup.and.saucer": Resource(subdirectory: "category_color/food", name: "color_food_9"),
        "car": Resource(subdirectory: "category_color/car", name: "color_car_1"),
        "cart": Resource(subdirectory: "category_color/shop", name: "color_shop_3"),
        "house": Resource(subdirectory: "category_color/daily", name: "color_daily_19"),
        "gamecontroller": Resource(subdirectory: "category_color/game", name: "color_game_2"),
        "cross.case": Resource(subdirectory: "category_color/health", name: "color_health_1"),
        "gift": Resource(subdirectory: "category_color/icon", name: "color_icon_18"),
        "ellipsis.circle": Resource(subdirectory: "category_color/icon", name: "color_icon_15"),
        "banknote": Resource(subdirectory: "category_color/finance", name: "color_finance_2"),
        "star": Resource(subdirectory: "category_color/game", name: "color_game_12"),
        "chart.line.uptrend.xyaxis": Resource(
            subdirectory: "category_color/finance",
            name: "color_finance_1"
        ),
        "tray.and.arrow.down": Resource(
            subdirectory: "category_color/finance",
            name: "color_finance_11"
        ),
    ]

    private static let defaultAccountResourceNames: [AccountKind: String] = [
        .fund: "account_xianjinqianbao",
        .credit: "account_xinyongka",
        .prepaid: "account_huiyuanka",
        .investment: "account_jijin",
        .receivable: "account_yingshou",
        .payable: "account_yingfu",
    ]

    /// 常见简称无法仅靠拼音包含关系命中，保留这组最小别名即可。
    private static let commonBankAliases: [String: String] = [
        "招行": "zhaoshangyinhang",
        "工行": "gongshangyinhang",
        "农行": "nongyeyinhang",
        "中行": "zhongguoyinhang",
        "建行": "jiansheyinhang",
        "交行": "jiaotongyinhang",
        "邮储": "youzhengchuxuyinhang",
        "浦发": "pufayinhang",
        "广发": "guangfayinhang",
        "民生": "minshengyinhang",
        "光大": "guangdayinhang",
        "华夏": "huaxiayinhang",
        "中信": "zhongxinyinhang",
        "平安": "pinganyinhang",
        "兴业": "xingyeyinhang",
    ]

    private static let imageCache = NSCache<NSString, UIImage>()
    private static let bankIndex = makeIndex(subdirectory: "bank")
    private static let accountIndex = makeIndex(
        subdirectory: "account",
        removingPrefix: "account_"
    )

    static func image(for category: Category) -> UIImage? {
        resourceURL(for: category).flatMap(loadImage)
    }

    static func image(
        forAccountName name: String,
        subtitle: String,
        kind: AccountKind,
        iconKindRawValue: String = "",
        iconPrimary: String = "",
        iconSecondary: String = "",
        iconIndex: Int = 0
    ) -> UIImage? {
        resourceURL(
            forAccountName: name,
            subtitle: subtitle,
            kind: kind,
            iconKindRawValue: iconKindRawValue,
            iconPrimary: iconPrimary,
            iconSecondary: iconSecondary,
            iconIndex: iconIndex
        ).flatMap(loadImage)
    }

    static func resourceURL(for category: Category) -> URL? {
        if let descriptorURL = descriptorResourceURL(
            kindRawValue: category.iconKindRawValue,
            primary: category.iconPrimary,
            secondary: category.iconSecondary,
            index: category.iconIndex
        ) {
            return descriptorURL
        }
        guard let resource = builtInCategoryResources[category.iconPrimary] else {
            return nil
        }
        return resourceURL(resource)
    }

    static func resourceURL(for account: Account) -> URL? {
        resourceURL(
            forAccountName: account.name,
            subtitle: account.subtitle,
            kind: account.kind ?? .fund,
            iconKindRawValue: account.iconKindRawValue,
            iconPrimary: account.iconPrimary,
            iconSecondary: account.iconSecondary,
            iconIndex: account.iconIndex
        )
    }

    static func resourceURL(forBuiltInCategorySymbol symbol: String) -> URL? {
        builtInCategoryResources[symbol].flatMap(resourceURL)
    }

    static func validSystemName(_ proposedName: String, fallback: String) -> String {
        proposedName.isEmpty || UIImage(systemName: proposedName) == nil
            ? fallback
            : proposedName
    }

    static func emoji(kindRawValue: String, primary: String) -> String? {
        guard IconDescriptor.Kind(rawValue: kindRawValue) == .emoji else { return nil }
        let value = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func resourceURL(
        forAccountName name: String,
        subtitle: String,
        kind: AccountKind,
        iconKindRawValue: String,
        iconPrimary: String,
        iconSecondary: String,
        iconIndex: Int
    ) -> URL? {
        if let descriptorURL = descriptorResourceURL(
            kindRawValue: iconKindRawValue,
            primary: iconPrimary,
            secondary: iconSecondary,
            index: iconIndex
        ) {
            return descriptorURL
        }
        let candidates = [subtitle, name].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if let bankURL = matchingURL(
            candidates: candidates,
            subdirectory: "bank",
            index: bankIndex,
            aliases: commonBankAliases
        ) {
            return bankURL
        }
        if let accountURL = matchingURL(
            candidates: [name],
            subdirectory: "account",
            filenamePrefix: "account_",
            index: accountIndex
        ) {
            return accountURL
        }
        guard let defaultName = defaultAccountResourceNames[kind] else { return nil }
        return resourceURL(Resource(subdirectory: "account", name: defaultName))
    }

    private static func descriptorResourceURL(
        kindRawValue: String,
        primary: String,
        secondary: String,
        index: Int
    ) -> URL? {
        guard IconDescriptor.Kind(rawValue: kindRawValue) == .asset else {
            return nil
        }
        let subdirectory = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        var name = secondary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subdirectory.isEmpty, !name.isEmpty,
              !subdirectory.contains(".."), !name.contains("/") else {
            return nil
        }
        if index > 0, !name.hasSuffix("_\(index)") {
            name += "_\(index)"
        }
        if let direct = resourceURL(Resource(subdirectory: subdirectory, name: name)) {
            return direct
        }
        switch subdirectory {
        case "bank":
            return matchingURL(
                candidates: [secondary],
                subdirectory: "bank",
                index: bankIndex
            )
        case "account":
            return matchingURL(
                candidates: [secondary],
                subdirectory: "account",
                filenamePrefix: "account_",
                index: accountIndex
            )
        default:
            return nil
        }
    }

    private static func matchingURL(
        candidates: [String],
        subdirectory: String,
        filenamePrefix: String = "",
        index: [IndexedResource],
        aliases: [String: String] = [:]
    ) -> URL? {
        let keys = candidates.map(normalized).filter { !$0.isEmpty }
        for key in keys {
            if let direct = resourceURL(
                Resource(subdirectory: subdirectory, name: filenamePrefix + key)
            ) {
                return direct
            }
            if let exact = index.first(where: { $0.key == key }) {
                return exact.url
            }
        }
        for candidate in candidates {
            let normalizedCandidate = normalized(candidate)
            if let aliasTarget = aliases.first(where: {
                normalizedCandidate.contains(normalized($0.key))
            })?.value {
                if let direct = resourceURL(
                    Resource(
                        subdirectory: subdirectory,
                        name: filenamePrefix + aliasTarget
                    )
                ) {
                    return direct
                }
                if let aliased = index.first(where: { $0.key == normalized(aliasTarget) }) {
                    return aliased.url
                }
            }
        }
        for key in keys where key.count >= 4 {
            if let contained = index.first(where: {
                key.contains($0.key) || ($0.key.count >= 4 && $0.key.contains(key))
            }) {
                return contained.url
            }
        }
        return nil
    }

    private static func makeIndex(
        subdirectory: String,
        removingPrefix prefix: String = ""
    ) -> [IndexedResource] {
        guard let resourceURL = Bundle.main.resourceURL else { return [] }
        let directoryURL = resourceURL
            .appendingPathComponent("Icons", isDirectory: true)
            .appendingPathComponent(subdirectory, isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension.lowercased() == "png" } ?? []
        return urls.map { url in
            var name = url.deletingPathExtension().lastPathComponent
            if !prefix.isEmpty, name.hasPrefix(prefix) {
                name.removeFirst(prefix.count)
            }
            return IndexedResource(key: normalized(name), url: url)
        }
        .sorted { $0.key.count > $1.key.count }
    }

    private static func normalized(_ value: String) -> String {
        let latin = value.applyingTransform(.toLatin, reverse: false) ?? value
        let folded = latin.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return String(
            folded.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)
        )
        // Foundation 会把金融语境中的「银行」音译为 yin-xing；资源 slug 使用 yin-hang。
        .replacingOccurrences(of: "yinxing", with: "yinhang")
    }

    private static func resourceURL(_ resource: Resource) -> URL? {
        Bundle.main.url(
            forResource: resource.name,
            withExtension: "png",
            subdirectory: "Icons/\(resource.subdirectory)"
        )
    }

    private static func loadImage(_ url: URL) -> UIImage? {
        let key = url.path as NSString
        if let cached = imageCache.object(forKey: key) {
            return cached
        }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }
}

struct CategoryIconView: View {
    private let category: Category?
    private let symbol: String
    let size: CGFloat

    init(category: Category, size: CGFloat) {
        self.category = category
        self.symbol = category.iconPrimary
        self.size = size
    }

    init(symbol: String, size: CGFloat) {
        self.category = nil
        self.symbol = symbol
        self.size = size
    }

    var body: some View {
        let image = category.flatMap(ZanzanIconCatalog.image)
            ?? ZanzanIconCatalog.resourceURL(forBuiltInCategorySymbol: symbol)
                .flatMap { UIImage(contentsOfFile: $0.path) }
        ResourceIconImage(
            image: image,
            emoji: category.flatMap {
                ZanzanIconCatalog.emoji(
                    kindRawValue: $0.iconKindRawValue,
                    primary: $0.iconPrimary
                )
            },
            fallbackSystemName: ZanzanIconCatalog.validSystemName(symbol, fallback: "tag"),
            size: size,
            fallbackColor: .primary
        )
    }
}

struct AccountIconView: View {
    private let name: String
    private let subtitle: String
    private let kind: AccountKind
    private let iconKindRawValue: String
    private let iconPrimary: String
    private let iconSecondary: String
    private let iconIndex: Int
    let size: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    init(account: Account, size: CGFloat) {
        name = account.name
        subtitle = account.subtitle
        kind = account.kind ?? .fund
        iconKindRawValue = account.iconKindRawValue
        iconPrimary = account.iconPrimary
        iconSecondary = account.iconSecondary
        iconIndex = account.iconIndex
        self.size = size
    }

    init(name: String, subtitle: String, kind: AccountKind, size: CGFloat) {
        self.name = name
        self.subtitle = subtitle
        self.kind = kind
        iconKindRawValue = ""
        iconPrimary = ""
        iconSecondary = ""
        iconIndex = 0
        self.size = size
    }

    var body: some View {
        let fallback = iconKindRawValue == IconDescriptor.Kind.symbol.rawValue
            ? ZanzanIconCatalog.validSystemName(iconPrimary, fallback: kind.symbolName)
            : kind.symbolName
        ZStack {
            Circle()
                .fill(
                    colorScheme == .light
                        ? Color.primary.opacity(0.82)
                        : Color.white.opacity(0.14)
                )
            ResourceIconImage(
                image: ZanzanIconCatalog.image(
                    forAccountName: name,
                    subtitle: subtitle,
                    kind: kind,
                    iconKindRawValue: iconKindRawValue,
                    iconPrimary: iconPrimary,
                    iconSecondary: iconSecondary,
                    iconIndex: iconIndex
                ),
                emoji: ZanzanIconCatalog.emoji(
                    kindRawValue: iconKindRawValue,
                    primary: iconPrimary
                ),
                fallbackSystemName: fallback,
                size: size - 8,
                fallbackColor: colorScheme == .light ? .white : .primary
            )
            .clipShape(.circle)
        }
        .frame(width: size, height: size)
        .overlay {
            Circle().stroke(.primary.opacity(0.08), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}

private struct ResourceIconImage: View {
    let image: UIImage?
    let emoji: String?
    let fallbackSystemName: String
    let size: CGFloat
    let fallbackColor: Color

    init(
        image: UIImage?,
        emoji: String? = nil,
        fallbackSystemName: String,
        size: CGFloat,
        fallbackColor: Color
    ) {
        self.image = image
        self.emoji = emoji
        self.fallbackSystemName = fallbackSystemName
        self.size = size
        self.fallbackColor = fallbackColor
    }

    var body: some View {
        Group {
            if let emoji {
                Text(verbatim: emoji)
                    .font(.system(size: size * 0.68))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: fallbackSystemName)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(fallbackColor)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
