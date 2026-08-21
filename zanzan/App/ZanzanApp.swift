import Foundation
import SwiftData
import SwiftUI

@main
struct ZanzanApp: App {
    private let container: ModelContainer

    @AppStorage(ZanzanBrandTheme.storageKey)
    private var brandThemeRawValue = ZanzanBrandTheme.defaultValue.rawValue
    @AppStorage(ZanzanAppLanguage.storageKey)
    private var languageRawValue = ZanzanAppLanguage.simplifiedChinese.rawValue

    init() {
        do {
            let usesInMemoryStore = ProcessInfo.processInfo.arguments.contains("-zanzan.uiTesting")
            container = try AppModelContainer.make(inMemory: usesInMemoryStore)
            let context = container.mainContext
            try FullBackupService(context: context).recoverInterruptedRestore()
            let seeder = DefaultDataSeeder(context: context)
            try seeder.seedIfNeeded()
            if usesInMemoryStore {
                try seeder.seedUITestTransactionsIfNeeded()
            }
        } catch {
            // 本地库创建/种子失败无降级路径：带上下文崩溃优于静默空转。
            fatalError("无法初始化数据库：\(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(
                    \.zanzanBrandTheme,
                    ZanzanBrandTheme.resolve(brandThemeRawValue)
                )
                .environment(
                    \.locale,
                    (ZanzanAppLanguage(rawValue: languageRawValue) ?? .simplifiedChinese).locale
                )
        }
        .modelContainer(container)
    }
}
