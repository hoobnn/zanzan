import SwiftUI

struct TransactionsHomeView: View {
    var body: some View {
        ContentUnavailableView(
            "还没有账单",
            systemImage: "list.bullet.rectangle",
            description: Text("记账功能开发中")
        )
        .navigationTitle("明细")
    }
}

#Preview {
    NavigationStack { TransactionsHomeView() }
}
