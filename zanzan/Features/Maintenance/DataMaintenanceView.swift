import SwiftData
import SwiftUI

struct DataMaintenanceView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Account> { !$0.isSoftDeleted }, sort: \Account.sortOrder)
    private var accounts: [Account]
    @Query(filter: #Predicate<BalanceSnapshot> { !$0.isSoftDeleted }, sort: \BalanceSnapshot.snapshotAt, order: .reverse)
    private var snapshots: [BalanceSnapshot]
    @Query(filter: #Predicate<Transaction> { !$0.isSoftDeleted })
    private var transactions: [Transaction]

    @State private var snapshotAt = Date.now
    @State private var commandMessage: String?
    @State private var commandErrorMessage: String?
    @State private var isConfirmingOrphanCleanup = false
    @State private var isConfirmingSnapshotRebuild = false
    @State private var isConfirmingSettlementMarkerRebuild = false

    var body: some View {
        List {
            Section {
                DatePicker("快照时点", selection: $snapshotAt, in: DraftLimits.occurredAtPickerRange)
                    .zanzanControlSurface()
                Button("为全部账户生成快照", systemImage: "camera.metering.center.weighted") {
                    generateSnapshots()
                }
                .buttonStyle(.glassProminent)
                Button("全量重建余额快照", systemImage: "arrow.triangle.2.circlepath") {
                    isConfirmingSnapshotRebuild = true
                }
                .confirmationDialog(
                    "全量重建余额快照？",
                    isPresented: $isConfirmingSnapshotRebuild,
                    titleVisibility: .visible
                ) {
                    Button("重建全部快照") { rebuildSnapshots() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("现有快照会被整体替换；账本、账户和流水不会改变。")
                }
                Button("重建报销/退款到账标记", systemImage: "link.badge.plus") {
                    isConfirmingSettlementMarkerRebuild = true
                }
                .confirmationDialog(
                    "重建报销/退款到账标记？",
                    isPresented: $isConfirmingSettlementMarkerRebuild,
                    titleVisibility: .visible
                ) {
                    Button("重建到账标记") { rebuildSettlementMarkers() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("系统会以报销/退款关联行为准修复到账标记，不会改动流水金额。")
                }
                Button("清理孤儿附件", systemImage: "trash") {
                    isConfirmingOrphanCleanup = true
                }
                .confirmationDialog(
                    "清理孤儿附件？",
                    isPresented: $isConfirmingOrphanCleanup,
                    titleVisibility: .visible
                ) {
                    Button("永久删除孤儿附件", role: .destructive) {
                        cleanOrphanAttachments()
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("未被任何流水引用的附件文件将被永久删除，此操作无法撤销。")
                }
            } footer: {
                Text("余额快照是可重建的查询缓存；历史流水变化后，受影响的快照会自动失效。")
            }

            Section("一致性检查") {
                if accounts.isEmpty {
                    Text("暂无账户")
                        .foregroundStyle(.secondary)
                }
                ForEach(accounts) { account in
                    consistencyRow(account)
                }
            }
        }
        .accessibilityIdentifier("screen.maintenance")
        .zanzanCompactList()
        .zanzanSketchPageBackground()
        .navigationTitle("数据维护")
        .alert("数据维护", isPresented: isPresentingMessage) { } message: {
            Text(commandMessage ?? "")
        }
        .alert("操作失败", isPresented: isPresentingError) { } message: {
            Text(commandErrorMessage ?? "")
        }
    }

    @ViewBuilder
    private func consistencyRow(_ account: Account) -> some View {
        let _ = (snapshots.count, transactions.count)
        switch Result(catching: {
            try BalanceSnapshotService(context: modelContext).verifyConsistency(accountUUID: account.uuid)
        }) {
        case let .success(report):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(account.name, systemImage: report.isConsistent ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(report.isConsistent ? Color.green : Color.red)
                    Spacer()
                    Text(report.isConsistent ? "一致" : "有偏差")
                        .font(.caption)
                        .foregroundStyle(report.isConsistent ? Color.green : Color.red)
                }
                Text(
                    "全量 \(formatAmount(report.derivedBalanceMinorUnits, currencyCode: account.currencyCode)) · 快照路径 \(formatAmount(report.snapshotBalanceMinorUnits, currencyCode: account.currencyCode))"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let latest = report.latestSnapshotAt {
                    Text(
                        "最新快照 \(ZanzanLocalization.formatted(latest, date: .abbreviated, time: .shortened))"
                    )
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("尚无快照，当前按全量派生")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
        case let .failure(error):
            Label("\(account.name)：\(error.localizedDescription)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private func generateSnapshots() {
        do {
            let created = try BalanceSnapshotService(context: modelContext)
                .generateSnapshots(asOf: snapshotAt)
            commandMessage = ZanzanLocalization.string( "已生成或刷新 \(created.count) 个账户快照")
        } catch {
            commandErrorMessage = error.localizedDescription
        }
    }

    private func cleanOrphanAttachments() {
        do {
            let count = try AttachmentStore(context: modelContext).cleanOrphans()
            commandMessage = ZanzanLocalization.string( "已清理 \(count) 个孤儿附件")
        } catch {
            commandErrorMessage = error.localizedDescription
        }
    }

    private func rebuildSnapshots() {
        do {
            let rebuilt = try BalanceSnapshotService(context: modelContext)
                .rebuildAllSnapshots(asOf: snapshotAt)
            commandMessage = ZanzanLocalization.string( "已重建 \(rebuilt.count) 个账户快照")
        } catch {
            commandErrorMessage = error.localizedDescription
        }
    }

    private func rebuildSettlementMarkers() {
        do {
            let repaired = try ReimbursementService(context: modelContext)
                .rebuildSettlementKinds()
            commandMessage = ZanzanLocalization.string( "已修复 \(repaired) 笔到账标记")
        } catch {
            commandErrorMessage = error.localizedDescription
        }
    }

    private var isPresentingMessage: Binding<Bool> {
        Binding(
            get: { commandMessage != nil },
            set: { if !$0 { commandMessage = nil } }
        )
    }

    private var isPresentingError: Binding<Bool> {
        Binding(
            get: { commandErrorMessage != nil },
            set: { if !$0 { commandErrorMessage = nil } }
        )
    }
}
