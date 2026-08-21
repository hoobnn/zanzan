import SwiftData
import SwiftUI

/// 账本 Tab 首页：解析当前账本（默认账本归一化）后转交账本页主体；
/// 账本管理与「我的」入口收进工具栏。
struct TransactionsHomeView: View {
    @Query(filter: #Predicate<Ledger> { !$0.isSoftDeleted }, sort: \Ledger.sortOrder)
    private var ledgers: [Ledger]

    @State private var monthAnchor: Date = .now
    @State private var selectedLedgerID: UUID?

    /// 默认账本归一化（设计文档 §4 同步合并兜底样板）：优先 isDefault，违例时回落首本。
    private var currentLedger: Ledger? {
        ledgers.first { $0.uuid == selectedLedgerID }
            ?? ledgers.first(where: \.isDefault)
            ?? ledgers.first
    }

    var body: some View {
        Group {
            if let ledger = currentLedger {
                TransactionListView(ledgerID: ledger.uuid, monthAnchor: $monthAnchor)
                    .id(ledger.uuid)
            } else {
                ContentUnavailableView(
                    "还没有账本",
                    systemImage: "book.closed",
                    description: Text("点右上角「账本管理」创建账本")
                )
                .zanzanSketchPageBackground()
            }
        }
        .navigationTitle("账本")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("切换账本") {
                        ForEach(ledgers) { ledger in
                            Button {
                                selectedLedgerID = ledger.uuid
                            } label: {
                                if ledger.uuid == currentLedger?.uuid {
                                    Label(ledger.name, systemImage: "checkmark")
                                } else {
                                    Text(ledger.name)
                                }
                            }
                        }
                    }
                    NavigationLink {
                        LedgersListView()
                    } label: {
                        Label("账本管理", systemImage: "gearshape")
                    }
                } label: {
                    Label(currentLedger?.name ?? ZanzanLocalization.string( "选择账本"), systemImage: "books.vertical")
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
