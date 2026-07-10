import SwiftUI

struct SettingsHomeView: View {
    var body: some View {
        List {
            Section("数据") {
                NavigationLink("账本管理") { LedgersListView() }
                NavigationLink("账户管理") { AccountsListView() }
            }

            Section("个性化") {
                NavigationLink("应用图标") { AppIconSettingsView() }
            }
        }
        .navigationTitle("我的")
    }
}

#Preview {
    NavigationStack { SettingsHomeView() }
}
