import SwiftUI

enum ZanzanStyle {
    static let compactRadius = 16.0
    static let compactRowIconSize = 32.0
    static let compactRowSpacing = 10.0
    nonisolated static let transactionRowFrameStorageKey = "zanzan.transactionRowFrame"
    nonisolated static let defaultShowsTransactionRowFrame = false

    static let sketchCardRadius = 20.0
    static let sketchCompactRadius = 14.0
    static let sketchSectionSpacing = 6.0
}

extension View {
    /// 全页环境色保持克制，让系统导航与工具栏玻璃有可折射的彩色手绘背景。
    func zanzanSketchPageBackground() -> some View {
        modifier(ZanzanPageBackgroundModifier())
    }

    /// 内容层使用标准材质，避免和导航、工具栏的 Liquid Glass 争夺层级。
    func zanzanSketchCard(tint: Color? = nil) -> some View {
        modifier(ZanzanCardModifier(overrideTint: tint))
    }

    /// 复杂管理页优先展示更多有效信息，同时保留系统要求的 44pt 最小触控区。
    func zanzanCompactList() -> some View {
        modifier(ZanzanCompactListModifier())
    }

    /// 给选择、日期、开关等原生控件补上统一的品牌操作表面，不改变其交互语义。
    func zanzanControlSurface() -> some View {
        modifier(ZanzanControlSurfaceModifier())
    }
}

private struct ZanzanPageBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.zanzanBrandTheme) private var brandTheme
    @AppStorage(ZanzanBackdropStyle.storageKey)
    private var backdropStyleRawValue = ZanzanBackdropStyle.defaultValue.rawValue

    func body(content: Content) -> some View {
        let backdropStyle = ZanzanBackdropStyle.resolve(backdropStyleRawValue)
        content
            .scrollContentBackground(.hidden)
            .background {
                ZStack {
                    Color(.systemBackground)
                    if backdropStyle != .plain {
                        LinearGradient(
                            colors: [
                                brandTheme.pageWash(for: colorScheme).opacity(
                                    brandTheme == .ivory ? 0.72 : 0.16
                                ),
                                Color(.systemBackground).opacity(0.96),
                                Color(.secondarySystemBackground).opacity(
                                    colorScheme == .dark ? 0.60 : 0.46
                                ),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    if backdropStyle == .sketch {
                        ZanzanSketchBackdrop()
                    }
                }
                .ignoresSafeArea()
            }
    }
}

private struct ZanzanCardModifier: ViewModifier {
    let overrideTint: Color?

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let tint = overrideTint?.opacity(colorScheme == .dark ? 0.08 : 0.06)
            ?? Color.clear
        let outline = overrideTint ?? Color.zanzanSky
        content
            .background {
                RoundedRectangle(cornerRadius: ZanzanStyle.sketchCardRadius)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: ZanzanStyle.sketchCardRadius)
                            .fill(tint)
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: ZanzanStyle.sketchCardRadius)
                    .strokeBorder(
                        outline.opacity(colorScheme == .dark ? 0.22 : 0.18),
                        lineWidth: 0.8
                    )
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.14 : 0.045),
                radius: 8,
                y: 2
            )
    }
}

private struct ZanzanCompactListModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listStyle(.insetGrouped)
            .listSectionSpacing(ZanzanStyle.sketchSectionSpacing)
            .environment(\.defaultMinListRowHeight, 44)
            .contentMargins(.top, 4, for: .scrollContent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
    }
}

private struct ZanzanControlSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: ZanzanStyle.sketchCompactRadius)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: ZanzanStyle.sketchCompactRadius)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.zanzanSky.opacity(0.055),
                                        Color.zanzanLilac.opacity(0.035),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: ZanzanStyle.sketchCompactRadius)
                    .strokeBorder(
                        Color.zanzanSky.opacity(colorScheme == .dark ? 0.34 : 0.24),
                        lineWidth: 0.8
                    )
            }
            .shadow(
                color: Color.zanzanSky.opacity(colorScheme == .dark ? 0.06 : 0.045),
                radius: 4,
                y: 1
            )
            .opacity(isEnabled ? 1 : 0.55)
            .tint(.zanzanSky)
    }
}
