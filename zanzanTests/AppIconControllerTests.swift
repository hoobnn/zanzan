import Foundation
import Testing
@testable import zanzan

@MainActor
struct AppIconControllerTests {
    @Test func 初始化时读取系统当前图标() {
        let application = AppIconApplicationStub(alternateIconName: "AppIconMidnight")
        let controller = AppIconController(application: application)

        #expect(controller.selectedIcon == .midnight)
        #expect(controller.pendingIcon == nil)
    }

    @Test func 切换成功后同步选中状态() async {
        let application = AppIconApplicationStub()
        let controller = AppIconController(application: application)

        await controller.select(.ivory)

        #expect(application.requestedIconNames.count == 1)
        #expect(application.requestedIconNames.first == "AppIconIvory")
        #expect(application.alternateIconName == "AppIconIvory")
        #expect(controller.selectedIcon == .ivory)
        #expect(controller.pendingIcon == nil)
        #expect(controller.failure == nil)
    }

    @Test func 切换失败后恢复系统实际状态并显示错误() async {
        let application = AppIconApplicationStub()
        let underlyingError = NSError(domain: "AppIconTests", code: 1)
        application.nextError = underlyingError
        let controller = AppIconController(application: application)

        await controller.select(.midnight)

        #expect(controller.selectedIcon == .emerald)
        #expect(controller.pendingIcon == nil)
        #expect(controller.failure?.message.contains(underlyingError.localizedDescription) == true)
    }

    @Test func 不支持备用图标时不调用系统切换() async {
        let application = AppIconApplicationStub(supportsAlternateIcons: false)
        let controller = AppIconController(application: application)

        await controller.select(.ivory)

        #expect(application.requestedIconNames.isEmpty)
        #expect(controller.selectedIcon == .emerald)
        #expect(controller.failure != nil)
    }
}
