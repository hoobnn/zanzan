import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            Tab("明细", systemImage: "list.bullet.rectangle") {
                NavigationStack { TransactionsHomeView() }
            }
            Tab("统计", systemImage: "chart.pie") {
                NavigationStack { StatsHomeView() }
            }
            Tab("我的", systemImage: "person.crop.circle") {
                NavigationStack { SettingsHomeView() }
            }
        }
    }
}

#Preview {
    RootView()
}
