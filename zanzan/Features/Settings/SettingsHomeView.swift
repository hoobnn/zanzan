import SwiftUI

enum SettingsRoute: Hashable {
    case ledgers
    case accounts
}

struct SettingsHomeView: View {
    var body: some View {
        List {
            Section("数据") {
                NavigationLink("账本管理", value: SettingsRoute.ledgers)
                NavigationLink("账户管理", value: SettingsRoute.accounts)
            }
        }
        .navigationTitle("我的")
        .navigationDestination(for: SettingsRoute.self) { route in
            switch route {
            case .ledgers: LedgersListView()
            case .accounts: AccountsListView()
            }
        }
    }
}

#Preview {
    NavigationStack { SettingsHomeView() }
}
