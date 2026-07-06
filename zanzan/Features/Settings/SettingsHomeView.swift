import SwiftUI

struct SettingsHomeView: View {
    var body: some View {
        ContentUnavailableView(
            "我的",
            systemImage: "person.crop.circle",
            description: Text("设置功能开发中")
        )
        .navigationTitle("我的")
    }
}

#Preview {
    NavigationStack { SettingsHomeView() }
}
