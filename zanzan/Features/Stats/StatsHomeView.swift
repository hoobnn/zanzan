import SwiftData
import SwiftUI

struct StatsHomeView: View {
    @Query(filter: #Predicate<Ledger> { !$0.isSoftDeleted }, sort: \Ledger.sortOrder)
    private var ledgers: [Ledger]

    @State private var selectedLedgerID: UUID?
    @State private var monthAnchor = Date.now

    private var selectedLedger: Ledger? {
        ledgers.first { $0.uuid == selectedLedgerID }
            ?? ledgers.first(where: \.isDefault)
            ?? ledgers.first
    }

    var body: some View {
        Group {
            if let ledger = selectedLedger {
                MonthlyStatsView(ledgerID: ledger.uuid, monthAnchor: $monthAnchor)
                    .id(ledger.uuid)
            } else {
                ContentUnavailableView(
                    "还没有账本",
                    systemImage: "chart.pie",
                    description: Text("创建账本并记一笔后，就能查看统计")
                )
                .zanzanSketchPageBackground()
            }
        }
        .navigationTitle("统计")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(ledgers) { ledger in
                        Button {
                            selectedLedgerID = ledger.uuid
                        } label: {
                            if ledger.uuid == selectedLedger?.uuid {
                                Label(ledger.name, systemImage: "checkmark")
                            } else {
                                Text(ledger.name)
                            }
                        }
                    }
                } label: {
                    Label(selectedLedger?.name ?? ZanzanLocalization.string( "选择账本"), systemImage: "books.vertical")
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
    NavigationStack { StatsHomeView() }
}
