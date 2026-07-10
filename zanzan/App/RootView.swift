import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            Tab("记账", systemImage: "list.bullet.rectangle") {
                NavigationStack { TransactionsHomeView() }
            }
            Tab("账本", systemImage: "book.closed") {
                NavigationStack { LedgersListView() }
            }
            Tab("资产", systemImage: "square.stack.3d.up.fill") {
                NavigationStack { AssetsHomeView() }
            }
            Tab("统计", systemImage: "chart.pie") {
                NavigationStack { StatsHomeView() }
            }
        }
    }
}

#Preview {
    RootView()
}
