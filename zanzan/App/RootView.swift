import OSLog
import SwiftData
import SwiftUI

/// 根视图：记账（点按弹全屏记一笔，不切页）/ 账本 / 资产 / 统计。
struct RootView: View {
    private static let recurringLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.ikuyu.zanzan",
        category: "RecurringRules"
    )

    private enum MainTab: Hashable {
        case record, ledger, assets, stats
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: MainTab = .ledger
    @State private var isRecording = false

    var body: some View {
        TabView(selection: $selection) {
            Tab("记账", systemImage: "plus", value: MainTab.record) {
                Color.clear // 永不展示：选中即回弹并弹出记一笔
            }
            Tab("账本", systemImage: "book.pages", value: MainTab.ledger) {
                NavigationStack { TransactionsHomeView() }
            }
            Tab("资产", systemImage: "square.stack.3d.up.fill", value: MainTab.assets) {
                NavigationStack { AssetsHomeView() }
            }
            Tab("统计", systemImage: "chart.bar.fill", value: MainTab.stats) {
                NavigationStack { StatsHomeView() }
            }
        }
        .onChange(of: selection) { oldValue, newValue in
            guard newValue == .record else { return }
            selection = oldValue
            isRecording = true
        }
        .fullScreenCover(isPresented: $isRecording) {
            RecordEntryView()
        }
        .tint(.primary)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            do {
                let outcome = try RecurringRuleService(context: modelContext)
                    .materializeDue(asOf: .now)
                if !outcome.skippedRules.isEmpty {
                    Self.recurringLogger.warning(
                        "自动补记跳过 \(outcome.skippedRules.count, privacy: .public) 条周期规则"
                    )
                }
            } catch {
                Self.recurringLogger.error(
                    "自动补记失败：\(error.localizedDescription, privacy: .private)"
                )
            }
        }
    }
}

#Preview {
    RootView()
}
