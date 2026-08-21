import PhotosUI
import SwiftData
import SwiftUI

struct TransactionAttachmentsView: View {
    let transaction: Transaction?
    @Binding var pendingAttachments: [Data]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var commandErrorMessage: String?
    @State private var isProcessingAttachments = false
    @State private var processedAttachmentCount = 0
    @State private var totalAttachmentCount = 0
    @State private var pendingRemoval: PendingRemoval?

    private enum PendingRemoval: Equatable {
        case saved(String)
        case pending(Int)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PhotosPicker(
                        selection: $pickerItems,
                        maxSelectionCount: 8,
                        matching: .images
                    ) {
                        Label("从照片中选择", systemImage: "photo.badge.plus")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .disabled(isProcessingAttachments)
                    .accessibilityLabel("从照片中选择附件")

                    if isProcessingAttachments {
                        ProgressView(
                            value: Double(processedAttachmentCount),
                            total: Double(max(totalAttachmentCount, 1))
                        ) {
                            Text("正在处理附件")
                        } currentValueLabel: {
                            Text("\(processedAttachmentCount)/\(totalAttachmentCount)")
                                .monospacedDigit()
                        }
                        .accessibilityValue("\(processedAttachmentCount)/\(totalAttachmentCount)")
                    }
                }

                if let transaction, !transaction.attachmentFileNames.isEmpty {
                    Section("已保存附件") {
                        ForEach(transaction.attachmentFileNames, id: \.self) { fileName in
                            HStack {
                                Label("票据照片", systemImage: "photo.fill")
                                Spacer()
                                ShareLink(item: AttachmentStore(context: modelContext).rootDirectory.appending(path: fileName)) {
                                    Label("分享", systemImage: "square.and.arrow.up")
                                        .labelStyle(.iconOnly)
                                }
                                .frame(width: 44, height: 44)
                                .contentShape(.rect)
                                .disabled(isProcessingAttachments)
                                .accessibilityLabel("分享票据照片")
                            }
                            .confirmationDialog(
                                "删除这个附件？",
                                isPresented: removalBinding(for: .saved(fileName)),
                                titleVisibility: .visible
                            ) {
                                Button("删除附件", role: .destructive) {
                                    remove(fileName)
                                }
                                Button("取消", role: .cancel) {}
                            } message: {
                                Text("删除后无法恢复。")
                            }
                            .swipeActions {
                                Button("删除", systemImage: "trash", role: .destructive) {
                                    pendingRemoval = .saved(fileName)
                                }
                                .disabled(isProcessingAttachments)
                            }
                        }
                    }
                }

                if !pendingAttachments.isEmpty {
                    Section("待随流水保存") {
                        ForEach(pendingAttachments.indices, id: \.self) { index in
                            HStack {
                                Label("待保存照片 \(index + 1)", systemImage: "photo")
                                Spacer()
                                Button("移除", role: .destructive) {
                                    pendingRemoval = .pending(index)
                                }
                                .buttonStyle(.borderless)
                                .frame(minWidth: 44, minHeight: 44)
                                .disabled(isProcessingAttachments)
                                .confirmationDialog(
                                    "移除待保存附件？",
                                    isPresented: removalBinding(for: .pending(index)),
                                    titleVisibility: .visible
                                ) {
                                    Button("移除附件", role: .destructive) {
                                        removePendingAttachment(at: index)
                                    }
                                    Button("取消", role: .cancel) {}
                                } message: {
                                    Text("移除后需要重新从照片中选择。")
                                }
                            }
                        }
                    }
                }

                if transaction?.attachmentFileNames.isEmpty != false,
                   pendingAttachments.isEmpty,
                   !isProcessingAttachments {
                    ContentUnavailableView(
                        "还没有附件",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("可添加票据、发票或其他凭证照片")
                    )
                    .listRowBackground(Color.clear)
                }
            }
            .zanzanCompactList()
            .zanzanSketchPageBackground()
            .navigationTitle("流水附件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .disabled(isProcessingAttachments)
                }
            }
            .onChange(of: pickerItems) {
                loadSelectedPhotos()
            }
            .alert("附件操作失败", isPresented: isPresentingError) { } message: {
                Text(commandErrorMessage ?? "")
            }
        }
        .interactiveDismissDisabled(isProcessingAttachments)
    }

    private func loadSelectedPhotos() {
        guard !pickerItems.isEmpty, !isProcessingAttachments else { return }
        let items = pickerItems
        pickerItems.removeAll()
        isProcessingAttachments = true
        processedAttachmentCount = 0
        totalAttachmentCount = items.count
        Task {
            defer {
                isProcessingAttachments = false
                processedAttachmentCount = 0
                totalAttachmentCount = 0
            }
            for item in items {
                defer { processedAttachmentCount += 1 }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        commandErrorMessage = ZanzanLocalization.string( "无法读取所选照片")
                        continue
                    }
                    pendingAttachments.append(data)
                } catch {
                    commandErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func removePendingAttachment(at index: Int) {
        guard pendingAttachments.indices.contains(index) else { return }
        pendingAttachments.remove(at: index)
    }

    private func remove(_ fileName: String) {
        guard let transaction else { return }
        do {
            try AttachmentStore(context: modelContext).remove(fileName, from: transaction.uuid)
        } catch {
            commandErrorMessage = error.localizedDescription
        }
    }

    private func removalBinding(for removal: PendingRemoval) -> Binding<Bool> {
        Binding(
            get: { pendingRemoval == removal },
            set: { if !$0, pendingRemoval == removal { pendingRemoval = nil } }
        )
    }

    private var isPresentingError: Binding<Bool> {
        Binding(
            get: { commandErrorMessage != nil },
            set: { if !$0 { commandErrorMessage = nil } }
        )
    }
}
