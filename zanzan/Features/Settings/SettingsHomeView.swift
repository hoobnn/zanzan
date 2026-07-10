import SwiftUI

struct SettingsHomeView: View {
    var body: some View {
        List {
            Section("数据") {
                NavigationLink("账本管理", value: SettingsRoute.ledgers)
                NavigationLink("账户管理", value: SettingsRoute.accounts)
            }

            Section("个性化") {
                NavigationLink("应用图标", value: SettingsRoute.appIcon)
            }
        }
        .navigationTitle("我的")
        .navigationDestination(for: SettingsRoute.self) { route in
            switch route {
            case .ledgers: LedgersListView()
            case .accounts: AccountsListView()
            case .appIcon: AppIconSettingsView()
            }
        }
    }
}

#Preview {
    NavigationStack { SettingsHomeView() }
}
