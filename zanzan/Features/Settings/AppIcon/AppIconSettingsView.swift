import SwiftUI

struct AppIconSettingsView: View {
    @State private var controller = AppIconController()

    var body: some View {
        @Bindable var controller = controller

        List {
            Section {
                ForEach(AppIconOption.allCases) { option in
                    Button {
                        select(option)
                    } label: {
                        AppIconOptionRow(
                            option: option,
                            isSelected: controller.selectedIcon == option,
                            isChanging: controller.pendingIcon == option
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(controller.pendingIcon != nil || !controller.supportsAlternateIcons)
                    .accessibilityLabel(option.title)
                    .accessibilityValue(controller.selectedIcon == option ? ZanzanLocalization.string( "已选择") : ZanzanLocalization.string( "未选择"))
                    .accessibilityHint("双击切换应用图标")
                }
            } footer: {
                Text("切换后，主屏幕、搜索与系统设置中的图标会同步更新。")
            }

            if !controller.supportsAlternateIcons {
                Section {
                    Label("当前设备或运行环境不支持切换应用图标", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("screen.appIcon")
        .zanzanCompactList()
        .zanzanSketchPageBackground()
        .navigationTitle("应用图标")
        .onAppear(perform: controller.refreshSelection)
        .alert(item: $controller.failure) { failure in
            Alert(
                title: Text("无法切换应用图标"),
                message: Text(failure.message)
            )
        }
    }

    private func select(_ option: AppIconOption) {
        Task {
            await controller.select(option)
        }
    }
}

#Preview {
    NavigationStack {
        AppIconSettingsView()
    }
}
