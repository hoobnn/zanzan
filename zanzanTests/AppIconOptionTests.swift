import Testing
@testable import zanzan

struct AppIconOptionTests {
    @Test func 备用图标名称与选项双向映射() {
        #expect(AppIconOption.emerald.alternateIconName == nil)
        #expect(AppIconOption.ivory.alternateIconName == "AppIconIvory")
        #expect(AppIconOption.midnight.alternateIconName == "AppIconMidnight")

        #expect(AppIconOption(alternateIconName: nil) == .emerald)
        #expect(AppIconOption(alternateIconName: "AppIconIvory") == .ivory)
        #expect(AppIconOption(alternateIconName: "AppIconMidnight") == .midnight)
    }

    @Test func 未知备用图标名称安全回退到主图标() {
        #expect(AppIconOption(alternateIconName: "UnknownIcon") == .emerald)
    }
}
