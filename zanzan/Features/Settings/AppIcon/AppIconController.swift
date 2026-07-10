import Observation
import UIKit

@MainActor
@Observable
final class AppIconController {
    private let application: any AppIconApplication

    private(set) var selectedIcon: AppIconOption
    private(set) var pendingIcon: AppIconOption?
    var failure: AppIconChangeFailure?

    var supportsAlternateIcons: Bool {
        application.supportsAlternateIcons
    }

    init(application: any AppIconApplication = UIApplication.shared) {
        self.application = application
        selectedIcon = AppIconOption(alternateIconName: application.alternateIconName)
    }

    func refreshSelection() {
        selectedIcon = AppIconOption(alternateIconName: application.alternateIconName)
    }

    func select(_ option: AppIconOption) async {
        failure = nil

        guard supportsAlternateIcons else {
            failure = AppIconChangeFailure(message: String(localized: "当前设备或运行环境不支持切换应用图标。"))
            return
        }

        guard option != selectedIcon else { return }

        pendingIcon = option
        defer { pendingIcon = nil }

        do {
            try await application.setAlternateIconName(option.alternateIconName)
            selectedIcon = option
        } catch {
            refreshSelection()
            failure = AppIconChangeFailure(message: String(localized: "\(error.localizedDescription) 请稍后重试。"))
        }
    }
}
