import SwiftData
import SwiftUI

/// 底栏「记账」全屏入口：解析当前账本（默认账本归一化）后转交记一笔表单。
struct RecordEntryCover: View {
    @Query(filter: #Predicate<StoredLedger> { !$0.isSoftDeleted }, sort: \StoredLedger.sortOrder)
    private var ledgers: [StoredLedger]
    @Environment(\.dismiss) private var dismiss

    private var currentLedger: StoredLedger? {
        ledgers.first(where: \.isDefault) ?? ledgers.first
    }

    var body: some View {
        if let ledger = currentLedger {
            TransactionFormView(ledgerID: ledger.uuid)
        } else {
            NavigationStack {
                ContentUnavailableView(
                    "还没有账本",
                    systemImage: "book.closed",
                    description: Text("请到「账本」页创建账本")
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
            }
        }
    }
}
