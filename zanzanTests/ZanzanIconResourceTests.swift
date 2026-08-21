import SwiftData
import Testing
import UIKit
@testable import zanzan

@MainActor
struct ZanzanIconResourceTests {
    @Test func 内置分类稳定键全部映射到可解码素材() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        try DefaultDataSeeder(context: context).seedIfNeeded()
        let categories = try context.fetch(
            FetchDescriptor<Category>(predicate: #Predicate { $0.isBuiltIn })
        )

        let missing = categories.compactMap { category -> String? in
            guard let url = ZanzanIconCatalog.resourceURL(for: category),
                  UIImage(contentsOfFile: url.path) != nil else {
                return "\(category.name):\(category.iconPrimary)"
            }
            return nil
        }

        #expect(categories.count == 16)
        #expect(missing.isEmpty)
    }

    @Test func 账户按银行名称和常见简称解析真实图标() throws {
        let bankCard = Account(name: "工资卡", kind: .fund)
        bankCard.subtitle = "招商银行"
        let shortNameCard = Account(name: "招行信用卡", kind: .credit)
        let detailedNameCard = Account(name: "中国银行工资卡", kind: .fund)

        let bankURL = try #require(ZanzanIconCatalog.resourceURL(for: bankCard))
        let shortNameURL = try #require(ZanzanIconCatalog.resourceURL(for: shortNameCard))
        let detailedNameURL = try #require(
            ZanzanIconCatalog.resourceURL(for: detailedNameCard)
        )

        #expect(bankURL.lastPathComponent == "zhaoshangyinhang.png")
        #expect(shortNameURL.lastPathComponent == "zhaoshangyinhang.png")
        #expect(detailedNameURL.lastPathComponent == "zhongguoyinhang.png")
        #expect(UIImage(contentsOfFile: bankURL.path) != nil)
    }

    @Test func 默认现金和未知账户均有实际账户图标() throws {
        let cash = Account(name: "现金", kind: .fund)
        cash.iconKindRawValue = IconDescriptor.Kind.symbol.rawValue
        cash.iconPrimary = "banknote"
        let investment = Account(name: "我的自定义账户", kind: .investment)

        let cashURL = try #require(ZanzanIconCatalog.resourceURL(for: cash))
        let investmentURL = try #require(ZanzanIconCatalog.resourceURL(for: investment))

        #expect(cashURL.lastPathComponent == "account_xianjinqianbao.png")
        #expect(investmentURL.lastPathComponent == "account_jijin.png")
    }

    @Test func asset四件套可直接解析且坏引用安全降级() {
        let category = Category(name: "测试", kind: .expense, sortOrder: 0)
        category.iconKindRawValue = IconDescriptor.Kind.asset.rawValue
        category.iconPrimary = "category_color/food"
        category.iconSecondary = "color_food"
        category.iconIndex = 11
        #expect(
            ZanzanIconCatalog.resourceURL(for: category)?.lastPathComponent
                == "color_food_11.png"
        )

        category.iconSecondary = "../invalid"
        #expect(ZanzanIconCatalog.resourceURL(for: category) == nil)
        #expect(
            ZanzanIconCatalog.validSystemName("not-a-real-symbol", fallback: "tag")
                == "tag"
        )
    }

    @Test func emoji描述符保留文本语义而不当作素材路径() {
        #expect(
            ZanzanIconCatalog.emoji(
                kindRawValue: IconDescriptor.Kind.emoji.rawValue,
                primary: " 💰 "
            ) == "💰"
        )
        #expect(
            ZanzanIconCatalog.emoji(
                kindRawValue: IconDescriptor.Kind.asset.rawValue,
                primary: "💰"
            ) == nil
        )
    }
}
