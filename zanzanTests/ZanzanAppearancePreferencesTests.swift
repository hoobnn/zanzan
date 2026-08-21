import Testing
@testable import zanzan

struct ZanzanAppearancePreferencesTests {
    @Test func 新安装默认白色主题() {
        #expect(ZanzanBrandTheme.defaultValue == .ivory)
        #expect(ZanzanBrandTheme.resolve(nil) == .ivory)
        #expect(ZanzanBrandTheme.resolve("unsupported") == .ivory)
    }

    @Test func 新安装默认手绘背景且流水无框() {
        #expect(ZanzanBackdropStyle.defaultValue == .sketch)
        #expect(ZanzanBackdropStyle.resolve(nil) == .sketch)
        #expect(ZanzanBackdropStyle.resolve("unsupported") == .sketch)
        #expect(ZanzanStyle.defaultShowsTransactionRowFrame == false)
    }
}
