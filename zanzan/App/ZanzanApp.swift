import SwiftData
import SwiftUI

@main
struct ZanzanApp: App {
    private let container: ModelContainer

    init() {
        do {
            container = try AppModelContainer.make()
            try DefaultDataSeeder(context: container.mainContext).seedIfNeeded()
        } catch {
            // 本地库创建/种子失败无降级路径：带上下文崩溃优于静默空转。
            fatalError("无法初始化数据库：\(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}
