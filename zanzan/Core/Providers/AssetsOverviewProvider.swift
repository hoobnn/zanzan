import Foundation
import SwiftData

/// 资产页只读投影：净资产/借贷汇总 + 按账户大类分组（余额派生，不落库）。
/// 跨账户汇总一律折本位币（§4 折算口径②）：非 CNY 账户余额按该币种全库最近一笔流水
/// 的汇率快照折算；无任何快照按 1:1 并经披露字段提示。单账户余额保持原币。
struct AssetsOverview {
    struct Item {
        let account: Account
        /// 账户自身币种的余额（分），保持原币展示
        let balanceMinorUnits: Int
    }

    struct Group {
        let kind: AccountKind
        let items: [Item]
        /// 组内正余额之和（本位币分，口径②折算）
        let balanceTotalMinorUnits: Int
        /// 组内负余额绝对值之和（本位币分，口径②折算）
        let debtTotalMinorUnits: Int
    }

    /// 未归档账户按大类分组（归档账户不进列表，余额照常计入汇总）
    let groups: [Group]
    /// 计入净资产账户的正余额之和（本位币分）
    let totalAssetsMinorUnits: Int
    /// 计入净资产账户的负余额绝对值之和（本位币分）
    let totalLiabilitiesMinorUnits: Int
    /// 总借入 = 应付类欠款（只计负余额取反求和，溢缴按 0，与分组小计同口径，本位币分）
    let borrowedTotalMinorUnits: Int
    /// 总借出 = 应收类正余额之和（透支按 0，与分组小计同口径，本位币分）
    let lentTotalMinorUnits: Int
    /// 口径②披露：折算实际用到的「币种 → 最近流水汇率快照」（UI 标注汇率时点用）。
    /// 带默认值的 var：memberwise init 生成默认参数，既有构造点（空态占位）零改动
    var fxRatesByCurrency: [String: Decimal] = [:]
    /// 无任何汇率快照、按 1:1 兜底折算的币种（UI 醒目提示用）
    var fxFallbackCurrencyCodes: Set<String> = []

    var netWorthMinorUnits: Int { totalAssetsMinorUnits - totalLiabilitiesMinorUnits }
}

struct AssetsOverviewProvider {
    let context: ModelContext

    func overview() throws -> AssetsOverview {
        let descriptor = FetchDescriptor<Account>(
            predicate: #Predicate { !$0.isSoftDeleted },
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        let accounts = try context.fetch(descriptor)
        let balanceProvider = AccountBalanceProvider(context: context)
        // ponytail: 每账户一次全量求和，量级上来再走 BalanceSnapshot 检查点。
        let items = try accounts.map { account in
            AssetsOverview.Item(account: account, balanceMinorUnits: try balanceProvider.balanceMinorUnits(of: account))
        }

        // 口径②折算：每账户附带折本位币后的余额，汇总一律用它（CNY 恒等，不进披露）
        let rateProvider = FxRateProvider(context: context)
        var ratesByCurrency: [String: Decimal] = [:]
        var fallbackCurrencyCodes: Set<String> = []
        let converted: [(item: AssetsOverview.Item, baseMinorUnits: Int)] = try items.map { item in
            let code = item.account.currencyCode
            guard code != FxConversion.baseCurrencyCode else { return (item, item.balanceMinorUnits) }
            if fallbackCurrencyCodes.contains(code) { return (item, item.balanceMinorUnits) }
            if let rate = try ratesByCurrency[code] ?? rateProvider.rate(for: code) {
                ratesByCurrency[code] = rate
                return (item, FxConversion.toBaseMinorUnits(item.balanceMinorUnits, rate: rate))
            }
            fallbackCurrencyCodes.insert(code) // 无快照按 1:1 并披露（§4 口径②）
            return (item, item.balanceMinorUnits)
        }

        let countedItems = converted.filter(\.item.account.isIncludedInNetWorth)
        let totalAssets = countedItems.map(\.baseMinorUnits).filter { $0 > 0 }.reduce(0, +)
        let totalLiabilities = -countedItems.map(\.baseMinorUnits).filter { $0 < 0 }.reduce(0, +)

        // 与分组小计同口径（裁决 9 精神）：借入只计负余额欠款（溢缴按 0）、借出只计正余额（透支按 0），
        // 不做净额抵减，避免顶部汇总与分组小计两个数
        let borrowed = -converted.filter { $0.item.account.kind == .payable }
            .map(\.baseMinorUnits).filter { $0 < 0 }.reduce(0, +)
        let lent = converted.filter { $0.item.account.kind == .receivable }
            .map(\.baseMinorUnits).filter { $0 > 0 }.reduce(0, +)

        let listedItems = converted.filter { !$0.item.account.isArchived }
        let groups = AccountKind.allCases.compactMap { kind -> AssetsOverview.Group? in
            let groupItems = listedItems.filter { $0.item.account.kind == kind }
            guard !groupItems.isEmpty else { return nil }
            return AssetsOverview.Group(
                kind: kind,
                items: groupItems.map(\.item),
                balanceTotalMinorUnits: groupItems.map(\.baseMinorUnits).filter { $0 > 0 }.reduce(0, +),
                debtTotalMinorUnits: -groupItems.map(\.baseMinorUnits).filter { $0 < 0 }.reduce(0, +)
            )
        }

        return AssetsOverview(
            groups: groups,
            totalAssetsMinorUnits: totalAssets,
            totalLiabilitiesMinorUnits: totalLiabilities,
            borrowedTotalMinorUnits: borrowed,
            lentTotalMinorUnits: lent,
            fxRatesByCurrency: ratesByCurrency,
            fxFallbackCurrencyCodes: fallbackCurrencyCodes
        )
    }
}
