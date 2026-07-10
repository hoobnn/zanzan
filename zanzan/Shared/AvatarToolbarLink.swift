import SwiftUI
import UIKit

/// 工具栏「我的」入口：Assets 中放入名为 `UserAvatar` 的图片即自动显示头像，
/// 否则回落 SF Symbol 占位。头像统一裁圆，适配工具栏圆钮。
struct AvatarToolbarLink: View {
    var body: some View {
        NavigationLink {
            SettingsHomeView()
        } label: {
            if let avatar = UIImage(named: "UserAvatar") {
                Image(uiImage: avatar)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 30, height: 30)
                    .clipShape(Circle())
            } else {
                Label("我的", systemImage: "person.crop.circle")
            }
        }
        .accessibilityLabel("我的")
    }
}
