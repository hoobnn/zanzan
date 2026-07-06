import SwiftData
import SwiftUI

@main
struct ZanzanApp: App {
    private let container: ModelContainer

    init() {
        do {
            container = try AppModelContainer.make()
        } catch {
            // 本地库创建失败无降级路径：带上下文崩溃优于静默空转。
            fatalError("无法创建数据库容器：\(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}
