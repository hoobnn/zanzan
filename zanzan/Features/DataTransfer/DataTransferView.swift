import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct DataTransferView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        filter: #Predicate<Ledger> { !$0.isSoftDeleted && !$0.isArchived },
        sort: \Ledger.sortOrder
    )
    private var ledgers: [Ledger]
    @Query(filter: #Predicate<ImportBatch> { !$0.isSoftDeleted }, sort: \ImportBatch.importedAt, order: .reverse)
    private var batches: [ImportBatch]

    @State private var selectedLedgerID: UUID?
    @State private var exportStart = Calendar.current.date(byAdding: .year, value: -1, to: .now) ?? .distantPast
    @State private var exportEnd = Date.now
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var exportDocument: CSVDocument?
    @State private var pendingCSV: String?
    @State private var pendingFileName = ""
    @State private var isConfirmingDuplicate = false
    @State private var commandMessage: String?
    @State private var commandErrorMessage: String?
    @State private var exportSummaryMessage: String?
    @State private var batchPendingUndo: ImportBatch?
    @State private var isImportingFullBackup = false
    @State private var isExportingFullBackup = false
    @State private var fullBackupDocument: ZanzanBackupDocument?
    @State private var pendingFullBackup: ZanzanBackupPackage?
    @State private var isConfirmingFullRestore = false
    @State private var isConfirmingSafetyRestore = false

    private var selectedLedger: Ledger? {
        ledgers.first { $0.uuid == selectedLedgerID }
            ?? ledgers.first(where: \.isDefault)
            ?? ledgers.first
    }

    var body: some View {
        List {
            Section {
                Button(
                    "导出完整备份",
                    systemImage: "archivebox",
                    action: prepareFullBackup
                )
                .fileExporter(
                    isPresented: $isExportingFullBackup,
                    document: fullBackupDocument,
                    contentType: .zanzanBackup,
                    defaultFilename: fullBackupFileName
                ) { result in
                    fullBackupDocument = nil
                    switch result {
                    case .success:
                        commandMessage = ZanzanLocalization.string("完整备份已导出")
                    case let .failure(error):
                        commandErrorMessage = error.localizedDescription
                    }
                }

                Button("从完整备份恢复", systemImage: "arrow.counterclockwise") {
                    isImportingFullBackup = true
                }
                .fileImporter(
                    isPresented: $isImportingFullBackup,
                    allowedContentTypes: [.zanzanBackup],
                    onCompletion: handleFullBackupImport
                )
                .confirmationDialog(
                    "恢复完整备份？",
                    isPresented: $isConfirmingFullRestore,
                    titleVisibility: .visible
                ) {
                    Button(
                        "完全覆盖并恢复",
                        role: .destructive,
                        action: restorePendingFullBackup
                    )
                    Button("取消", role: .cancel) {
                        pendingFullBackup = nil
                    }
                } message: {
                    Text("恢复会用备份中的全部数据和附件完全覆盖当前数据；操作前会先创建恢复前安全备份。")
                }
                .onChange(of: isConfirmingFullRestore) { _, isPresented in
                    if !isPresented {
                        pendingFullBackup = nil
                    }
                }

                Button(
                    "恢复上次自动备份",
                    systemImage: "clock.arrow.circlepath",
                    action: prepareSafetyBackupRestore
                )
                .confirmationDialog(
                    "恢复上次自动备份？",
                    isPresented: $isConfirmingSafetyRestore,
                    titleVisibility: .visible
                ) {
                    Button(
                        "完全覆盖并恢复",
                        role: .destructive,
                        action: restorePendingFullBackup
                    )
                    Button("取消", role: .cancel) {
                        pendingFullBackup = nil
                    }
                } message: {
                    Text("恢复会用自动备份中的全部数据和附件完全覆盖当前数据；操作前会先保存当前状态。")
                }
                .onChange(of: isConfirmingSafetyRestore) { _, isPresented in
                    if !isPresented {
                        pendingFullBackup = nil
                    }
                }
            } header: {
                Text("完整备份")
            } footer: {
                Text("包含全部业务数据和附件。CSV 仅用于普通流水交换，不能替代完整备份。")
            }

            Section("目标账本") {
                Picker("账本", selection: $selectedLedgerID) {
                    ForEach(ledgers) { ledger in
                        Text(ledger.name).tag(ledger.uuid as UUID?)
                    }
                }
                .zanzanControlSurface()
            }

            Section {
                Button("选择 CSV 文件", systemImage: "square.and.arrow.down") {
                    isImporting = true
                }
                .disabled(selectedLedger == nil)
            } header: {
                Text("导入")
            }

            Section {
                DatePicker("开始时间", selection: $exportStart, in: DraftLimits.occurredAtPickerRange)
                    .zanzanControlSurface()
                DatePicker("结束时间", selection: $exportEnd, in: exportStart...DraftLimits.occurredAtRange.upperBound)
                    .zanzanControlSurface()
                Button("导出 CSV", systemImage: "square.and.arrow.up") {
                    prepareExport()
                }
                .disabled(selectedLedger == nil)
            } header: {
                Text("导出")
            }

            Section {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("支持新 11 列多币种格式，也兼容旧 8 列 CNY 格式；任一行错误都会整批取消。")
                        Text("CSV 用于普通流水交换，不是完整备份；标签、附件和自动化来源不会保留，余额校准及报销/退款到账会被跳过并明确报告。")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } label: {
                    Label("CSV 格式与限制", systemImage: "info.circle")
                }
                .zanzanControlSurface()
            }

            Section("导入历史") {
                if batches.isEmpty {
                    Text("暂无导入记录")
                        .foregroundStyle(.secondary)
                }
                ForEach(batches) { batch in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(batch.fileName)
                        Text(
                            "\(batch.transactionCount) 笔 · \(ZanzanLocalization.formatted(batch.importedAt, date: .abbreviated, time: .shortened))"
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("整批撤销", systemImage: "arrow.uturn.backward", role: .destructive) {
                            batchPendingUndo = batch
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("screen.dataTransfer")
        .zanzanCompactList()
        .zanzanSketchPageBackground()
        .navigationTitle("数据导入导出")
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.commaSeparatedText, .plainText]
        ) { result in
            handleImport(result)
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: exportFileName
        ) { result in
            switch result {
            case .success:
                commandMessage = exportSummaryMessage
                exportSummaryMessage = nil
            case let .failure(error):
                commandErrorMessage = error.localizedDescription
            }
        }
        .confirmationDialog(
            "撤销整批导入？",
            isPresented: Binding(
                get: { batchPendingUndo != nil },
                set: { if !$0 { batchPendingUndo = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("撤销整批流水", role: .destructive) {
                guard let batch = batchPendingUndo else { return }
                batchPendingUndo = nil
                undo(batch)
            }
            Button("取消", role: .cancel) { batchPendingUndo = nil }
        } message: {
            Text("该批次创建的全部流水都会被移入最近删除，账户余额也会随之变化。")
        }
        .confirmationDialog(
            "疑似重复导入",
            isPresented: $isConfirmingDuplicate,
            titleVisibility: .visible
        ) {
            Button("仍然导入") { importPendingCSV() }
            Button("取消", role: .cancel) { clearPendingImport() }
        } message: {
            Text("已存在内容完全相同的活跃导入批次。继续会产生重复流水。")
        }
        .alert("数据导入导出", isPresented: isPresentingMessage) { } message: {
            Text(commandMessage ?? "")
        }
        .alert("操作失败", isPresented: isPresentingError) { } message: {
            Text(commandErrorMessage ?? "")
        }
    }

    private var exportFileName: String {
        "zanzan-\(selectedLedger?.name ?? "ledger")-\(Date.now.formatted(.iso8601.year().month().day()))"
    }

    private var fullBackupFileName: String {
        "zanzan-\(Date.now.formatted(.iso8601.year().month().day()))"
    }

    private func prepareFullBackup() {
        do {
            fullBackupDocument = ZanzanBackupDocument(
                package: try FullBackupService(context: modelContext).export()
            )
            isExportingFullBackup = true
        } catch {
            commandErrorMessage = error.localizedDescription
        }
    }

    private func handleFullBackupImport(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            pendingFullBackup = try ZanzanBackupPackage.read(from: url)
            isConfirmingFullRestore = true
        } catch {
            commandErrorMessage = error.localizedDescription
        }
    }

    private func prepareSafetyBackupRestore() {
        do {
            guard let package = try FullBackupService(context: modelContext)
                .loadSafetyBackup() else {
                commandErrorMessage = ZanzanLocalization.string("暂无恢复前安全备份")
                return
            }
            pendingFullBackup = package
            isConfirmingSafetyRestore = true
        } catch {
            commandErrorMessage = error.localizedDescription
        }
    }

    private func restorePendingFullBackup() {
        guard let package = pendingFullBackup else { return }
        pendingFullBackup = nil
        batchPendingUndo = nil
        clearPendingImport()
        do {
            let summary = try FullBackupService(context: modelContext).restore(package)
            selectedLedgerID = nil
            commandMessage = ZanzanLocalization.string(
                "已恢复 \(summary.recordCount) 条记录和 \(summary.attachmentCount) 个附件"
            )
        } catch {
            commandErrorMessage = error.localizedDescription
        }
    }

    private func prepareExport() {
        guard let ledger = selectedLedger else { return }
        do {
            let result = try TransactionCSVExporter(context: modelContext)
                .export(ledgerID: ledger.uuid, from: exportStart, to: exportEnd)
            exportDocument = CSVDocument(text: result.csv)
            exportSummaryMessage = result.skippedCount == 0
                ? ZanzanLocalization.string("已导出 \(result.exportedCount) 笔普通流水")
                : ZanzanLocalization.string(
                    "已导出 \(result.exportedCount) 笔，另有 \(result.skippedCount) 笔余额校准、到账或不完整流水未导出"
                )
            isExporting = true
        } catch {
            commandErrorMessage = error.localizedDescription
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            let csv = try TransactionCSVImporter.readCSV(from: url)
            pendingCSV = csv
            pendingFileName = url.lastPathComponent
            let importer = TransactionCSVImporter(context: modelContext)
            let hash = TransactionCSVImporter.contentHash(of: csv)
            if try importer.existingBatch(withContentHash: hash) != nil {
                isConfirmingDuplicate = true
            } else {
                importPendingCSV()
            }
        } catch {
            commandErrorMessage = error.localizedDescription
        }
    }

    private func importPendingCSV() {
        guard let csv = pendingCSV, let ledger = selectedLedger else {
            clearPendingImport()
            return
        }
        do {
            let batch = try TransactionCSVImporter(context: modelContext).importTransactions(
                csv: csv,
                fileName: pendingFileName,
                ledgerID: ledger.uuid,
                importedAt: .now
            )
            commandMessage = ZanzanLocalization.string( "已导入 \(batch.transactionCount) 笔流水")
            clearPendingImport()
        } catch let error as TransactionCSVImportError {
            if case let .invalidRows(rows) = error {
                let details = rows.prefix(20)
                    .map { ZanzanLocalization.string( "第 \($0.line) 行：\($0.message)") }
                    .joined(separator: "\n")
                let suffix = rows.count > 20 ? ZanzanLocalization.string( "\n另有 \(rows.count - 20) 行错误") : ""
                commandErrorMessage = "\(error.localizedDescription)\n\(details)\(suffix)"
            } else {
                commandErrorMessage = error.localizedDescription
            }
            clearPendingImport()
        } catch {
            commandErrorMessage = error.localizedDescription
            clearPendingImport()
        }
    }

    private func undo(_ batch: ImportBatch) {
        do {
            try TransactionCSVImporter(context: modelContext).undoBatch(batchUUID: batch.uuid)
            commandMessage = ZanzanLocalization.string( "已撤销 \(batch.transactionCount) 笔导入流水")
        } catch {
            commandErrorMessage = error.localizedDescription
        }
    }

    private func clearPendingImport() {
        pendingCSV = nil
        pendingFileName = ""
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
