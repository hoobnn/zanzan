import Foundation
import SwiftData

/// 资产页只读投影：净资产/借贷汇总 + 按账户大类分组（余额派生，不落库）。
struct AssetsOverview {
    struct Item {
        let account: Account
        let balanceMinorUnits: Int
    }

    struct Group {
        let kind: AccountKind
        let items: [Item]
        /// 组内正余额之和
        let balanceTotalMinorUnits: Int
        /// 组内负余额绝对值之和
        let debtTotalMinorUnits: Int
    }

    /// 未归档账户按大类分组（归档账户不进列表，余额照常计入汇总）
    let groups: [Group]
    /// 计入净资产账户的正余额之和
    let totalAssetsMinorUnits: Int
    /// 计入净资产账户的负余额绝对值之和
    let totalLiabilitiesMinorUnits: Int
    /// 总借入 = 应付类欠款（余额取反后求和）
    let borrowedTotalMinorUnits: Int
    /// 总借出 = 应收类余额之和
    let lentTotalMinorUnits: Int

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

        let countedItems = items.filter(\.account.isIncludedInNetWorth)
        let totalAssets = countedItems.map(\.balanceMinorUnits).filter { $0 > 0 }.reduce(0, +)
        let totalLiabilities = -countedItems.map(\.balanceMinorUnits).filter { $0 < 0 }.reduce(0, +)

        let borrowed = -items.filter { $0.account.kind == .payable }.map(\.balanceMinorUnits).reduce(0, +)
        let lent = items.filter { $0.account.kind == .receivable }.map(\.balanceMinorUnits).reduce(0, +)

        let listedItems = items.filter { !$0.account.isArchived }
        let groups = AccountKind.allCases.compactMap { kind -> AssetsOverview.Group? in
            let groupItems = listedItems.filter { $0.account.kind == kind }
            guard !groupItems.isEmpty else { return nil }
            return AssetsOverview.Group(
                kind: kind,
                items: groupItems,
                balanceTotalMinorUnits: groupItems.map(\.balanceMinorUnits).filter { $0 > 0 }.reduce(0, +),
                debtTotalMinorUnits: -groupItems.map(\.balanceMinorUnits).filter { $0 < 0 }.reduce(0, +)
            )
        }

        return AssetsOverview(
            groups: groups,
            totalAssetsMinorUnits: totalAssets,
            totalLiabilitiesMinorUnits: totalLiabilities,
            borrowedTotalMinorUnits: borrowed,
            lentTotalMinorUnits: lent
        )
    }
}
