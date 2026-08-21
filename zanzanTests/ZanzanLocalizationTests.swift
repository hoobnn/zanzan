import Foundation
import Testing
@testable import zanzan

@Suite(.serialized)
struct ZanzanLocalizationTests {
    @Test func 未设置或存入非法语言时回退简体中文() {
        let defaults = UserDefaults.standard
        let key = ZanzanAppLanguage.storageKey
        let previousValue = defaults.object(forKey: key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        #expect(ZanzanLocalization.currentLanguage == .simplifiedChinese)

        defaults.set("unsupported", forKey: key)
        #expect(ZanzanLocalization.currentLanguage == .simplifiedChinese)
    }

    @Test func 显式语言返回对应字符串() {
        #expect(ZanzanLocalization.string("保存", language: .simplifiedChinese) == "保存")
        #expect(ZanzanLocalization.string("保存", language: .english) == "Save")
        #expect(ZanzanLocalization.string("全部类型", language: .english) == "All Types")
        #expect(ZanzanLocalization.string("全部账户", language: .english) == "All Accounts")
        #expect(ZanzanLocalization.string("全部标签", language: .english) == "All Tags")
        #expect(ZanzanLocalization.string("本月总预算", language: .english) == "Total Budget This Month")
        #expect(ZanzanLocalization.string("彩色手绘", language: .english) == "Color Sketch")
        #expect(ZanzanLocalization.string("显示流水行边框", language: .english) == "Show Transaction Row Frames")
    }

    @Test func 日期格式跟随显式语言() {
        let date = Date(timeIntervalSinceReferenceDate: 1_252_800)
        let chinese = ZanzanLocalization.formatted(
            date,
            date: .abbreviated,
            time: .omitted,
            language: .simplifiedChinese
        )
        let english = ZanzanLocalization.formatted(
            date,
            date: .abbreviated,
            time: .omitted,
            language: .english
        )

        #expect(chinese.contains("年"))
        #expect(chinese.contains("月"))
        #expect(english.contains("Jan"))
        #expect(english.contains("2001"))
    }

    @MainActor
    @Test func 金额格式跟随显式语言() {
        #expect(formatAmount(123_456, language: .simplifiedChinese) == "¥1,234.56")
        #expect(formatAmount(123_456, language: .english) == "CN¥1,234.56")
    }
}
