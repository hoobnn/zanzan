import SwiftData
import SwiftUI

/// 账本 Tab 首页：解析当前账本（默认账本归一化）后转交账本页主体；
/// 账本管理与「我的」入口收进工具栏。
struct TransactionsHomeView: View {
    @Query(filter: #Predicate<StoredLedger> { !$0.isSoftDeleted }, sort: \StoredLedger.sortOrder)
    private var ledgers: [StoredLedger]

    @State private var monthAnchor: Date = .now

    /// 默认账本归一化（设计文档 §4 同步合并兜底样板）：优先 isDefault，违例时回落首本。
    private var currentLedger: StoredLedger? {
        ledgers.first(where: \.isDefault) ?? ledgers.first
    }

    var body: some View {
        Group {
            if let ledger = currentLedger {
                TransactionListView(ledgerID: ledger.uuid, monthAnchor: $monthAnchor)
            } else {
                ContentUnavailableView(
                    "还没有账本",
                    systemImage: "book.closed",
                    description: Text("点右上角「账本管理」创建账本")
                )
            }
        }
        .navigationTitle("账本")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    LedgersListView()
                } label: {
                    Label("账本管理", systemImage: "ellipsis")
                }
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                AvatarToolbarLink()
            }
        }
    }
}

#Preview {
    NavigationStack { TransactionsHomeView() }
}
