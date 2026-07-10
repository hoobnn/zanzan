import SwiftData
import SwiftUI

/// 记一笔/编辑流水全屏页：类型胶囊 + 分类宫格 + 功能胶囊行 + 金额卡 + 自定义计算键盘。
struct TransactionFormView: View {
    private let ledgerID: UUID
    private let editingUUID: UUID?
    private let isKindLocked: Bool

    @State private var draft: TransactionDraft
    @State private var expression: AmountExpression
    @State private var validationMessage: String?
    @State private var isPickingTime = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(
        filter: #Predicate<Account> { !$0.isSoftDeleted && !$0.isArchived && $0.isSelectableForRecord },
        sort: \Account.sortOrder
    )
    private var accounts: [Account]

    @Query(
        filter: #Predicate<Category> { !$0.isSoftDeleted && !$0.isArchived },
        sort: \Category.sortOrder
    )
    private var categories: [Category]

    init(ledgerID: UUID, editing transaction: Transaction? = nil) {
        self.ledgerID = ledgerID
        self.editingUUID = transaction?.uuid
        self.isKindLocked = transaction != nil
        var draft = TransactionDraft()
        if let transaction {
            draft.kind = transaction.kind ?? .expense
            draft.amountString = MoneyAmount.decimalString(fromMinorUnits: transaction.amountMinorUnits)
            draft.occurredAt = transaction.occurredAt
            draft.note = transaction.note
            draft.accountUUID = transaction.account?.uuid
            draft.targetAccountUUID = transaction.targetAccount?.uuid
            draft.categoryUUID = transaction.category?.uuid
            draft.feeString = transaction.feeMinorUnits == 0
                ? ""
                : MoneyAmount.decimalString(fromMinorUnits: transaction.feeMinorUnits)
            // 回填汇率/到账金额：编辑不得让历史快照被最近快照静默改写（§4 口径①）
            draft.fxRateString = transaction.fxRateToBase.map { "\($0)" } ?? ""
            draft.targetAmountString = transaction.targetAmountMinorUnits
                .map { MoneyAmount.decimalString(fromMinorUnits: $0) } ?? ""
        }
        _draft = State(initialValue: draft)
        _expression = State(initialValue: AmountExpression(decimalString: draft.amountString))
    }

    var body: some View {
        VStack(spacing: 12) {
            headerBar
            Group {
                if draft.kind == .transfer {
                    transferPickers
                } else {
                    categoryGrid
                        .overlay(alignment: .bottom) {
                            RecordChipsRow(accounts: accounts, selectedAccountUUID: $draft.accountUUID)
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            amountCard
            RecordKeypadView(expression: $expression) { save(andContinue: false) }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .onChange(of: draft.kind) {
            draft.categoryUUID = nil // 切方向清分类，防方向不匹配
        }
        .onAppear {
            if draft.accountUUID == nil { draft.accountUUID = accounts.first?.uuid }
        }
        .sheet(isPresented: $isPickingTime) {
            DatePicker("记账时间", selection: $draft.occurredAt)
                .datePickerStyle(.graphical)
                .padding()
                .presentationDetents([.medium, .large])
        }
        .alert("无法保存", isPresented: isPresentingError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(validationMessage ?? "")
        }
    }

    // MARK: - 顶栏

    private var headerBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
            Spacer()
            kindSegments
            Spacer()
            Button("保存再记") { save(andContinue: true) }
                .font(.body.weight(.medium))
                .opacity(editingUUID == nil ? 1 : 0)
                .disabled(editingUUID != nil)
        }
    }

    private var kindSegments: some View {
        HStack(spacing: 0) {
            ForEach(TransactionKind.allCases, id: \.self) { kind in
                let isSelected = draft.kind == kind
                Button {
                    withAnimation(.snappy) { draft.kind = kind }
                } label: {
                    Text(kind.displayName)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Color(.secondarySystemGroupedBackground))
                                    .stroke(Color(.systemGray4), lineWidth: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(Color(.secondarySystemGroupedBackground)))
        .disabled(isKindLocked)
    }

    // MARK: - 分类宫格

    /// 当前方向一级分类；二级分类选择是后续切片（C2），角标仅提示有子分类。
    private var parentCategories: [Category] {
        categories.filter { $0.kind == draft.kind && $0.parentID == nil }
    }

    private var categoryGrid: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 18) {
                ForEach(parentCategories) { category in
                    categoryCell(category)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 64) // 底部给胶囊行让位
        }
        .scrollIndicators(.hidden)
    }

    private func categoryCell(_ category: Category) -> some View {
        let isSelected = draft.categoryUUID == category.uuid
        return Button {
            draft.categoryUUID = category.uuid
        } label: {
            VStack(spacing: 6) {
                Circle()
                    .fill(isSelected ? Color.zanzanAccent : Color(.systemGray5))
                    .frame(width: 54, height: 54)
                    .overlay {
                        Image(systemName: category.iconPrimary.isEmpty ? "circle.dashed" : category.iconPrimary)
                            .font(.system(size: 20))
                            .foregroundStyle(isSelected ? .white : .primary)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if hasChildren(category) {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 14, height: 14)
                                .background(Circle().fill(Color(.systemGray)))
                        }
                    }
                Text(category.name)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func hasChildren(_ category: Category) -> Bool {
        categories.contains { $0.parentID == category.uuid }
    }

    // MARK: - 转账

    private var transferPickers: some View {
        VStack(spacing: 0) {
            accountMenuRow(title: "转出账户", selection: $draft.accountUUID)
            Divider().padding(.leading, 16)
            accountMenuRow(title: "转入账户", selection: $draft.targetAccountUUID)
            Divider().padding(.leading, 16)
            HStack {
                Text("手续费")
                Spacer()
                TextField("0.00（可选）", text: $draft.feeString)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            .padding(16)
        }
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemGroupedBackground)))
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func accountMenuRow(title: LocalizedStringKey, selection: Binding<UUID?>) -> some View {
        Menu {
            ForEach(accounts) { account in
                Button(account.name) { selection.wrappedValue = account.uuid }
            }
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Text(accountName(selection.wrappedValue) ?? String(localized: "请选择"))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
        }
    }

    private func accountName(_ uuid: UUID?) -> String? {
        accounts.first { $0.uuid == uuid }?.name
    }

    // MARK: - 金额卡

    private var amountCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "¥\(expression.displayText)")
                .font(.system(size: 36, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(Color.zanzanAccent)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.numericText())
                .accessibilityLabel(Text("金额 \(expression.displayText)"))
            Divider()
            HStack(spacing: 12) {
                Button {
                    isPickingTime = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                        Text(timeText)
                    }
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color(.systemGray6)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("记账时间")
                TextField("点击填写备注", text: $draft.note)
                    .font(.subheadline)
                // ponytail: 展开更多选项入口预留
                Image(systemName: "chevron.up")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var timeText: String {
        if Calendar.current.isDateInToday(draft.occurredAt) {
            draft.occurredAt.formatted(date: .omitted, time: .shortened)
        } else {
            draft.occurredAt.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
        }
    }

    // MARK: - 保存

    private func save(andContinue: Bool) {
        draft.amountString = expression.finalizedDecimalString()
        do {
            let commands = TransactionService(context: modelContext)
            if let editingUUID {
                try commands.updateTransaction(uuid: editingUUID, draft: draft)
                dismiss()
                return
            }
            try commands.recordTransaction(draft, ledgerID: ledgerID)
            if andContinue {
                expression = AmountExpression()
                draft.amountString = ""
                draft.note = ""
            } else {
                dismiss()
            }
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private var isPresentingError: Binding<Bool> {
        Binding(
            get: { validationMessage != nil },
            set: { if !$0 { validationMessage = nil } }
        )
    }
}
