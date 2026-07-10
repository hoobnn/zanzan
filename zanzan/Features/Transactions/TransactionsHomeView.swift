import SwiftData
import SwiftUI

/// 记账 Tab 首页：解析当前账本（默认账本归一化）后转交列表。
struct TransactionsHomeView: View {
    @Query(filter: #Predicate<StoredLedger> { !$0.isSoftDeleted }, sort: \StoredLedger.sortOrder)
    private var ledgers: [StoredLedger]

    /// 默认账本归一化（设计文档 §4 同步合并兜底样板）：优先 isDefault，违例时回落首本。
    private var currentLedger: StoredLedger? {
        ledgers.first(where: \.isDefault) ?? ledgers.first
    }

    var body: some View {
        if let ledger = currentLedger {
            TransactionListView(ledgerID: ledger.uuid)
                .navigationTitle(ledger.name)
        } else {
            ContentUnavailableView(
                "还没有账本",
                systemImage: "book.closed",
                description: Text("请到「账本」页创建账本")
            )
            .navigationTitle("记账")
        }
    }
}

#Preview {
    NavigationStack { TransactionsHomeView() }
}
