import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @AppStorage(ZanzanBrandTheme.storageKey)
    private var brandThemeRawValue = ZanzanBrandTheme.defaultValue.rawValue
    @AppStorage(ZanzanAppLanguage.storageKey)
    private var languageRawValue = ZanzanAppLanguage.simplifiedChinese.rawValue
    @AppStorage(ZanzanBackdropStyle.storageKey)
    private var backdropStyleRawValue = ZanzanBackdropStyle.defaultValue.rawValue
    @AppStorage(ZanzanStyle.transactionRowFrameStorageKey)
    private var showsTransactionRowFrame = ZanzanStyle.defaultShowsTransactionRowFrame

    private var brandTheme: ZanzanBrandTheme {
        ZanzanBrandTheme.resolve(brandThemeRawValue)
    }

    private var language: ZanzanAppLanguage {
        ZanzanAppLanguage(rawValue: languageRawValue) ?? .simplifiedChinese
    }

    private var themeColumns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 280 : 140),
                spacing: 8
            ),
        ]
    }

    var body: some View {
        List {
            Section {
                LazyVGrid(columns: themeColumns, spacing: 8) {
                    ForEach(ZanzanBrandTheme.allCases) { theme in
                        Button {
                            brandThemeRawValue = theme.rawValue
                        } label: {
                            ZanzanBrandThemeOption(
                                theme: theme,
                                isSelected: brandTheme == theme
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(brandTheme == theme ? "已选择" : "未选择")
                        .accessibilityIdentifier("appearance.theme.\(theme.rawValue)")
                    }
                }
                .padding(.vertical, 2)
            } header: {
                Text("界面主题")
            } footer: {
                Text(ZanzanLocalization.string(brandTheme.subtitle))
            }

            Section {
                Picker("页面背景", selection: $backdropStyleRawValue) {
                    ForEach(ZanzanBackdropStyle.allCases) { style in
                        Text(ZanzanLocalization.string(style.title))
                            .tag(style.rawValue)
                            .accessibilityIdentifier("appearance.backdrop.\(style.rawValue)")
                    }
                }
                .pickerStyle(.segmented)
                .zanzanControlSurface()
                .accessibilityIdentifier("appearance.backdrop")

                Toggle("显示流水行边框", isOn: $showsTransactionRowFrame)
                    .zanzanControlSurface()
                    .accessibilityIdentifier("appearance.transactionRowFrame")
            } header: {
                Text("显示风格")
            } footer: {
                Text("背景和流水边框只影响外观，不会改动账目数据。")
            }

            Section {
                Picker("应用语言", selection: $languageRawValue) {
                    ForEach(ZanzanAppLanguage.allCases) { option in
                        Text(ZanzanLocalization.string(option.title)).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .zanzanControlSurface()
                .labelsHidden()
                .accessibilityLabel("应用语言")
            } header: {
                Text("语言")
            } footer: {
                Text("语言切换立即生效。已有账本、账户和分类名称属于用户数据，不会被自动改写。")
            }
        }
        .accessibilityIdentifier("screen.appearance")
        .zanzanCompactList()
        .zanzanSketchPageBackground()
        .navigationTitle("外观与语言")
    }
}

#Preview {
    NavigationStack { AppearanceSettingsView() }
}
