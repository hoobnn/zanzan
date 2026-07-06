import SwiftUI

struct StatsHomeView: View {
    var body: some View {
        ContentUnavailableView(
            "暂无统计",
            systemImage: "chart.pie",
            description: Text("统计功能开发中")
        )
        .navigationTitle("统计")
    }
}

#Preview {
    NavigationStack { StatsHomeView() }
}
