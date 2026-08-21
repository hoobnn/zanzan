import Foundation
import Testing

struct LocalizationCatalogTests {
    @Test func 非过期词条都有完整英文翻译() throws {
        let catalog = try loadCatalog()
        #expect(catalog.sourceLanguage == "zh-Hans")

        for (key, entry) in catalog.strings where entry.extractionState != "stale" {
            let english = entry.localizations?["en"]
            #expect(english != nil, "缺少英文翻译：\(key)")
            guard let english else { continue }

            let units = english.units
            #expect(!units.isEmpty, "英文翻译为空：\(key)")
            #expect(
                units.allSatisfy { $0.unit.state == "translated" && !$0.unit.value.isEmpty },
                "英文翻译未完成：\(key)"
            )
        }
    }

    @Test func 英文翻译占位符与源词条一致() throws {
        let catalog = try loadCatalog()

        for (key, entry) in catalog.strings where entry.extractionState != "stale" {
            guard let english = entry.localizations?["en"] else { continue }
            let sourcePlaceholders = placeholders(in: key)

            for translated in english.units {
                var expected = sourcePlaceholders
                let actual = placeholders(in: translated.unit.value)
                if translated.variation == "one", actual != expected,
                   let countIndex = expected.firstIndex(of: "%lld") {
                    expected.remove(at: countIndex)
                }
                #expect(actual == expected, "占位符不一致：\(key)")
            }
        }
    }

    @Test func 英文翻译没有意外首尾空白() throws {
        let catalog = try loadCatalog()

        for (key, entry) in catalog.strings
            where entry.extractionState != "stale" && !key.hasPrefix("\n") {
            guard let english = entry.localizations?["en"] else { continue }
            for translated in english.units {
                let value = translated.unit.value
                #expect(
                    value == value.trimmingCharacters(in: .whitespacesAndNewlines),
                    "英文翻译含意外首尾空白：\(key)"
                )
            }
        }
    }

    @Test func Xcode原生提取覆盖关键当前源词条() throws {
        let catalog = try loadCatalog()
        let requiredKeys = [
            "删除这笔流水？",
            "删除后，这笔流水将不再计入余额和统计。",
            "正在处理附件",
            "无法读取所选照片",
            "移除待保存附件？",
            "账户「%@」存在多个同名候选，无法确定",
            "分类「%@」存在多个同名候选，无法确定",
            "单次最多补记 %lld 期，仍有到期流水待处理，请再次执行补记",
            "标签不存在或已删除",
            "标签已归档，不能挂到新流水；可先取消归档",
            "只能使用全局标签或本账本的标签",
            "校准时间超出可记账范围",
            "校准金额或所需调整额超出单笔可支持范围",
            "父分类已归档，请先取消归档",
            "归档账本不能设为默认，请先取消归档",
            "计划类型无法识别，请升级应用后重试",
            "预算金额超出可支持范围",
            "授信池名称不能超过 %lld 字",
            "息费收取方式",
            "预设仅套用公开的计算规则，不包含费率或息费金额；请以合同或账单为准，保存前可逐项调整。",
            "全部类型",
            "全部账户",
            "全部标签",
            "本月总预算",
            "缺少 %@ 汇率快照，跨币种汇总暂按 1:1 折算",
            "已忽略币种不一致的成员卡：%@",
            "重建报销/退款到账标记",
            "已修复 %lld 笔到账标记",
            "到账标记或关联类型由更高版本创建，请升级 App 后重试",
            "界面主题",
            "白色玻璃表面作为默认主题，深色模式继续跟随系统。",
            "轻柔的翡翠雾只调整背景氛围，收支颜色仍按业务语义显示。",
            "页面背景",
            "彩色手绘",
            "柔和渐变",
            "纯净背景",
            "显示流水行边框",
            "账户图标",
            "根据银行、渠道或账户名称自动匹配",
            "预置分类会自动使用对应的彩色图标",
        ]

        for key in requiredKeys {
            let entry = catalog.strings[key]
            #expect(entry != nil, "Xcode 未提取关键源词条：\(key)")
            #expect(entry?.extractionState != "stale", "关键源词条已 stale：\(key)")
        }
    }

    @Test func InfoPlist目录源语言与英文完整() throws {
        let catalog = try loadCatalog(named: "InfoPlist")
        #expect(catalog.sourceLanguage == "zh-Hans")

        for key in ["CFBundleDisplayName", "CFBundleName"] {
            let english = catalog.strings[key]?.localizations?["en"]
            #expect(english != nil, "InfoPlist 缺少英文翻译：\(key)")
            #expect(
                english?.units.allSatisfy {
                    $0.unit.state == "translated" && !$0.unit.value.isEmpty
                } == true,
                "InfoPlist 英文翻译未完成：\(key)"
            )
        }
    }

    private func loadCatalog(named name: String = "Localizable") throws -> StringCatalog {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let catalogURL = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "zanzan/\(name).xcstrings")
        return try JSONDecoder().decode(StringCatalog.self, from: Data(contentsOf: catalogURL))
    }

    private func placeholders(in value: String) -> [String] {
        value.matches(of: /%(?:[0-9]+\$)?(?:lld|@)/)
            .map { match in
                let token = String(match.output)
                guard let dollar = token.firstIndex(of: "$") else { return token }
                return "%" + String(token[token.index(after: dollar)...])
            }
            .sorted()
    }
}

private struct StringCatalog: Decodable {
    let sourceLanguage: String
    let strings: [String: CatalogEntry]
}

private struct CatalogEntry: Decodable {
    let extractionState: String?
    let localizations: [String: CatalogLocalization]?
}

private struct CatalogLocalization: Decodable {
    let stringUnit: CatalogStringUnit?
    let variations: CatalogVariations?

    var units: [(variation: String?, unit: CatalogStringUnit)] {
        var result: [(variation: String?, unit: CatalogStringUnit)] =
            stringUnit.map { [(variation: nil, unit: $0)] } ?? []
        result += variations?.plural?.map { (variation: $0.key, unit: $0.value.stringUnit) } ?? []
        return result
    }
}

private struct CatalogVariations: Decodable {
    let plural: [String: CatalogVariation]?
}

private struct CatalogVariation: Decodable {
    let stringUnit: CatalogStringUnit
}

private struct CatalogStringUnit: Decodable {
    let state: String
    let value: String
}
