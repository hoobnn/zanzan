import SwiftData
import SwiftUI

/// 记一笔/编辑流水全屏页：类型胶囊 + 分类宫格 + 功能胶囊行 + 金额区 + 自定义计算键盘。
struct TransactionFormView: View {
    private let ledgerID: UUID
    private let editingUUID: UUID?
    private let editingTransaction: Transaction?
    private let isKindLocked: Bool
    private let initialReimbursementStatus: ReimbursementStatus?

    @State private var draft: TransactionDraft
    @State private var expression: AmountExpression
    @State private var validationMessage: String?
    @State private var isPickingTime = false
    @State private var isShowingAdvancedOptions = false
    @State private var isSaving = false
    @State private var selectedTagUUIDs: Set<UUID>
    @State private var isReimbursementMarked: Bool
    @State private var pendingAttachments: [Data] = []
    @State private var isManagingAttachments = false
    @State private var expandedParentCategoryUUID: UUID?
    @FocusState private var isSystemInputFocused: Bool
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ScaledMetric(relativeTo: .footnote) private var categoryMinimumWidth: CGFloat = 72

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

    @Query(
        filter: #Predicate<Tag> { !$0.isSoftDeleted && !$0.isArchived },
        sort: \Tag.sortOrder
    )
    private var tags: [Tag]

    init(ledgerID: UUID, editing transaction: Transaction? = nil) {
        self.ledgerID = ledgerID
        self.editingUUID = transaction?.uuid
        self.editingTransaction = transaction
        self.isKindLocked = transaction != nil
        let initialTagUUIDs = Set(transaction?.tags?.map(\.uuid) ?? [])
        self.initialReimbursementStatus = transaction?.reimbursementStatus
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
            draft.locationName = transaction.locationName
            draft.locationLatitudeString = transaction.locationLatitude.map { String($0) } ?? ""
            draft.locationLongitudeString = transaction.locationLongitude.map { String($0) } ?? ""
            draft.isExcludedFromBudget = transaction.isExcludedFromBudget
            draft.isExcludedFromStats = transaction.isExcludedFromStats
        }
        _draft = State(initialValue: draft)
        _expression = State(initialValue: AmountExpression(decimalString: draft.amountString))
        _selectedTagUUIDs = State(initialValue: initialTagUUIDs)
        _isReimbursementMarked = State(initialValue: transaction?.reimbursementStatus != nil)
        _expandedParentCategoryUUID = State(
            initialValue: transaction?.category?.parentID ?? transaction?.category?.uuid
        )
    }

    var body: some View {
        Group {
            if verticalSizeClass == .compact {
                landscapeLayout
            } else if dynamicTypeSize.isAccessibilitySize {
                accessibilityLayout
            } else {
                portraitLayout
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .zanzanSketchPageBackground()
        .tint(draft.kind.tintColor(for: colorScheme))
        .onChange(of: draft.kind) {
            draft.categoryUUID = nil // 切方向清分类，防方向不匹配
            expandedParentCategoryUUID = nil
        }
        .onAppear {
            if draft.accountUUID == nil { draft.accountUUID = accounts.first?.uuid }
            if expandedParentCategoryUUID == nil,
               let selectedCategory,
               let parentID = selectedCategory.parentID {
                expandedParentCategoryUUID = parentID
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") {
                    isSystemInputFocused = false
                }
            }
        }
        .sheet(isPresented: $isPickingTime) {
            DatePicker("记账时间", selection: $draft.occurredAt, in: DraftLimits.occurredAtPickerRange)
                .datePickerStyle(.graphical)
                .zanzanControlSurface()
                .padding()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isManagingAttachments) {
            TransactionAttachmentsView(
                transaction: editingTransaction,
                pendingAttachments: $pendingAttachments
            )
        }
        .sheet(isPresented: $isShowingAdvancedOptions) {
            TransactionAdvancedOptionsView(draft: $draft)
        }
        .alert("无法保存", isPresented: isPresentingError) { } message: {
            Text(validationMessage ?? "")
        }
    }

    private var portraitLayout: some View {
        GeometryReader { proxy in
            VStack(spacing: 8) {
                headerBar
                    .fixedSize(horizontal: false, vertical: true)

                if draft.kind == .transfer {
                    transferPickers
                } else {
                    VStack(spacing: 6) {
                        categorySelectionContent
                        recordChips
                    }
                }

                Spacer(minLength: 8)
                amountDisplay
                    .accessibilityIdentifier("record.amountSection")
                Spacer(minLength: 8)
                amountMetadata
                if !isSystemInputFocused {
                    recordKeypad
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
    }

    private var landscapeLayout: some View {
        VStack(spacing: 4) {
            headerBar
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    transactionDetails
                        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                    amountSection
                        .frame(width: 240, alignment: .top)
                    if !isSystemInputFocused {
                        recordKeypad
                            .frame(width: 300)
                    }
                }

                HStack(alignment: .top, spacing: 8) {
                    ScrollView {
                        VStack(spacing: 4) {
                            if draft.kind == .transfer {
                                transferPickers
                            } else {
                                categorySelectionContent
                                recordChips
                            }
                            amountSection
                        }
                        .padding(.bottom, 4)
                    }
                    .scrollIndicators(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if !isSystemInputFocused {
                        recordKeypad
                            .frame(minWidth: 250, maxWidth: 320)
                    }
                }
            }
        }
    }

    private var accessibilityLayout: some View {
        ScrollView {
            VStack(spacing: 12) {
                headerBar
                if draft.kind == .transfer {
                    transferPickers
                } else {
                    categorySelectionContent
                    recordChips
                }
                amountSection
                if !isSystemInputFocused {
                    recordKeypad
                }
            }
            .padding(.bottom, 12)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private var transactionDetails: some View {
        if draft.kind == .transfer {
            transferPickers
                .frame(maxHeight: .infinity, alignment: .top)
        } else {
            VStack(spacing: 4) {
                categoryGrid
                recordChips
            }
        }
    }

    private var recordChips: some View {
        RecordChipsRow(
            accounts: accounts,
            tags: availableTags,
            showsReimbursement: draft.kind == .expense,
            locksReimbursement: initialReimbursementStatus == .settled,
            onManageAttachments: {
                isSystemInputFocused = false
                isManagingAttachments = true
            },
            selectedAccountUUID: $draft.accountUUID,
            selectedTagUUIDs: $selectedTagUUIDs,
            isReimbursementMarked: $isReimbursementMarked
        )
    }

    private var recordKeypad: some View {
        RecordKeypadView(expression: $expression, kind: draft.kind) {
            save(andContinue: false)
        }
        .disabled(isSaving)
    }

    // MARK: - 顶栏

    private var headerBar: some View {
        ViewThatFits(in: .horizontal) {
            ZStack {
                kindSegments
                HStack {
                    closeButton
                    Spacer()
                    saveAndContinueButton
                }
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 6) {
                HStack {
                    closeButton
                    Spacer()
                    saveAndContinueButton
                }
                ScrollView(.horizontal) {
                    kindSegments
                        .fixedSize(horizontal: true, vertical: false)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Label("关闭", systemImage: "xmark")
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: .circle)
        }
        .buttonStyle(.plain)
        .tint(.primary)
    }

    @ViewBuilder
    private var saveAndContinueButton: some View {
        if editingUUID == nil {
            Button { save(andContinue: true) } label: {
                Text("保存再记")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(.thinMaterial, in: .capsule)
            }
                .buttonStyle(.plain)
                .disabled(isSaving)
        }
    }

    private var kindSegments: some View {
        HStack(spacing: 2) {
            ForEach(TransactionKind.allCases, id: \.self) { kind in
                let isSelected = draft.kind == kind
                Button {
                    select(kind)
                } label: {
                    Text(kind.displayName)
                        .font(.subheadline)
                        .bold(isSelected)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .foregroundStyle(
                            isSelected
                                ? kind.tintColor(for: colorScheme)
                                : Color.secondary
                        )
                        .padding(.horizontal, 11)
                        .frame(height: 40)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(kind.tintColor(for: colorScheme).opacity(0.13))
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityValue(isSelected ? "已选择" : "未选择")
                .accessibilityIdentifier("record.kind.\(kind.rawValue)")
            }
        }
        .padding(2)
        .background(.thinMaterial, in: .capsule)
        .disabled(isKindLocked)
    }

    // MARK: - 分类宫格

    /// 当前方向一级分类；选择带子项的一级分类后，在同页渐进披露二级分类。
    private var availableCategories: [Category] {
        categories.filter { $0.ledgerID == nil || $0.ledgerID == ledgerID }
    }

    private var parentCategories: [Category] {
        availableCategories.filter { $0.kind == draft.kind && $0.parentID == nil }
    }

    private var selectedCategory: Category? {
        availableCategories.first { $0.uuid == draft.categoryUUID }
    }

    private var expandedParentCategory: Category? {
        guard let expandedParentCategoryUUID else { return nil }
        return parentCategories.first { $0.uuid == expandedParentCategoryUUID }
    }

    private var expandedChildCategories: [Category] {
        guard let expandedParentCategoryUUID else { return [] }
        return availableCategories.filter {
            $0.kind == draft.kind && $0.parentID == expandedParentCategoryUUID
        }
    }

    private var availableTags: [Tag] {
        tags.filter { $0.ledgerID == nil || $0.ledgerID == ledgerID }
    }

    private var selectedAccount: Account? {
        accounts.first { $0.uuid == draft.accountUUID }
    }

    private var targetAccount: Account? {
        accounts.first { $0.uuid == draft.targetAccountUUID }
    }

    private var usesForeignCurrency: Bool {
        selectedAccount?.currencyCode != nil
            && selectedAccount?.currencyCode != FxConversion.baseCurrencyCode
    }

    private var isCrossCurrencyTransfer: Bool {
        draft.kind == .transfer
            && selectedAccount?.currencyCode != nil
            && targetAccount?.currencyCode != nil
            && selectedAccount?.currencyCode != targetAccount?.currencyCode
    }

    private var categoryGrid: some View {
        ScrollView {
            categorySelectionContent
        }
        .scrollIndicators(.hidden)
    }

    private var categorySelectionContent: some View {
        VStack(spacing: 4) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: categoryMinimumWidth), spacing: 8)],
                spacing: 6
            ) {
                ForEach(parentCategories) { category in
                    categoryCell(category)
                }
            }

            if let parent = expandedParentCategory, !expandedChildCategories.isEmpty {
                childCategoryPicker(parent: parent, children: expandedChildCategories)
            }
        }
        .padding(.vertical, 2)
    }

    private func categoryCell(_ category: Category) -> some View {
        let isSelected = draft.categoryUUID == category.uuid
        let containsSelection = selectedCategory?.parentID == category.uuid
        return Button {
            draft.categoryUUID = category.uuid
            expandedParentCategoryUUID = availableCategories.contains { $0.parentID == category.uuid }
                ? category.uuid
                : nil
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    if isSelected || containsSelection {
                        Circle()
                            .fill(draft.kind.tintColor(for: colorScheme).opacity(0.13))
                    }
                    CategoryIconView(category: category, size: 32)
                }
                    .frame(width: 44, height: 44)
                Text(category.name)
                    .font(.caption)
                    .foregroundStyle(
                        isSelected || containsSelection
                            ? draft.kind.tintColor(for: colorScheme)
                            : Color.primary
                    )
                    .bold(isSelected || containsSelection)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 66)
            .background {
                if isSelected || containsSelection {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(draft.kind.tintColor(for: colorScheme).opacity(0.06))
                }
            }
            .overlay {
                if isSelected || containsSelection {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(draft.kind.tintColor(for: colorScheme).opacity(0.18), lineWidth: 1)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected || containsSelection ? .isSelected : [])
        .accessibilityValue(isSelected || containsSelection ? "已选择" : "未选择")
    }

    private func childCategoryPicker(parent: Category, children: [Category]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("二级分类", systemImage: "square.grid.2x2")
                .font(.subheadline)
                .bold()
                .foregroundStyle(.secondary)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    childCategoryButton(parent)
                    ForEach(children) { childCategoryButton($0) }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(10)
        .zanzanSketchCard(tint: .zanzanLilac)
    }

    private func childCategoryButton(_ category: Category) -> some View {
        let isSelected = draft.categoryUUID == category.uuid
        return Button {
            draft.categoryUUID = category.uuid
        } label: {
            Label {
                Text(category.name)
            } icon: {
                CategoryIconView(category: category, size: 18)
            }
            .font(.subheadline)
            .bold(isSelected)
            .foregroundStyle(
                isSelected
                    ? draft.kind.onTintColor(for: colorScheme)
                    : Color.primary
            )
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background {
                if isSelected {
                    Capsule().fill(draft.kind.prominentGradient(for: colorScheme))
                }
            }
        }
        .buttonStyle(.glass)
        .tint(isSelected ? draft.kind.tintColor(for: colorScheme) : nil)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(isSelected ? "已选择" : "未选择")
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
                    .focused($isSystemInputFocused)
                    .textFieldStyle(.zanzan)
            }
            .padding(16)
        }
        .padding(4)
        .zanzanSketchCard(tint: .zanzanSky)
    }

    private func accountMenuRow(title: LocalizedStringKey, selection: Binding<UUID?>) -> some View {
        Menu {
            ForEach(accounts) { account in
                Button {
                    selection.wrappedValue = account.uuid
                } label: {
                    Label {
                        Text(account.name)
                    } icon: {
                        AccountIconView(account: account, size: 22)
                    }
                }
            }
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if let account = account(selection.wrappedValue) {
                    AccountIconView(account: account, size: 24)
                }
                Text(account(selection.wrappedValue)?.name ?? ZanzanLocalization.string( "请选择"))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
        }
    }

    private func account(_ uuid: UUID?) -> Account? {
        accounts.first { $0.uuid == uuid }
    }

    // MARK: - 金额区

    private var amountSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            amountDisplay
            amountMetadata
        }
        .accessibilityIdentifier("record.amountSection")
    }

    private var amountDisplay: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(verbatim: amountCurrencyPrefix)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(draft.kind.tintColor(for: colorScheme))
            Text(verbatim: expression.displayText)
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .contentTransition(reduceMotion ? .identity : .numericText())
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityLabel(
            Text(
                verbatim: "\(ZanzanLocalization.string("金额")) \(amountCurrencyCode) \(expression.displayText)"
            )
        )
    }

    private var amountMetadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    amountTimeButton
                    advancedOptionsButton
                    noteField
                        .frame(minWidth: 120)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        amountTimeButton
                        advancedOptionsButton
                        Spacer(minLength: 0)
                    }
                    noteField
                }
            }
            if usesForeignCurrency || isCrossCurrencyTransfer {
                Divider()
                HStack {
                    if usesForeignCurrency {
                        TextField(
                            "1 \(selectedAccount?.currencyCode ?? "") = ? CNY",
                            text: $draft.fxRateString
                        )
                        .keyboardType(.decimalPad)
                        .focused($isSystemInputFocused)
                        .textFieldStyle(.zanzan)
                    }
                    if isCrossCurrencyTransfer {
                        TextField(
                            "到账金额（\(targetAccount?.currencyCode ?? "")）",
                            text: $draft.targetAmountString
                        )
                        .keyboardType(.decimalPad)
                        .focused($isSystemInputFocused)
                        .textFieldStyle(.zanzan)
                    }
                }
                .font(.subheadline)
            }
        }
    }

    private var amountTimeButton: some View {
        Button {
            isSystemInputFocused = false
            isPickingTime = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock")
                Text(timeText)
            }
            .font(.footnote)
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(.thinMaterial, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("记账时间")
        .accessibilityValue(Text(verbatim: timeText))
    }

    private var advancedOptionsButton: some View {
        Button("高级设置", systemImage: "slider.horizontal.3") {
            isSystemInputFocused = false
            isShowingAdvancedOptions = true
        }
        .labelStyle(.iconOnly)
        .frame(width: 44, height: 44)
        .background(.thinMaterial, in: .circle)
        .buttonStyle(.plain)
        .accessibilityLabel("高级设置")
    }

    private var noteField: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("点击填写备注", text: $draft.note)
                .font(.subheadline)
                .focused($isSystemInputFocused)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(.thinMaterial, in: .capsule)
    }

    private var amountCurrencyCode: String {
        selectedAccount?.currencyCode
            ?? accounts.first?.currencyCode
            ?? FxConversion.baseCurrencyCode
    }

    private var amountCurrencyPrefix: String {
        amountCurrencyCode == FxConversion.baseCurrencyCode ? "¥" : "\(amountCurrencyCode) "
    }

    private var timeText: String {
        if Calendar.current.isDateInToday(draft.occurredAt) {
            ZanzanLocalization.formatted(draft.occurredAt, date: .omitted, time: .shortened)
        } else {
            ZanzanLocalization.formatted(
                draft.occurredAt,
                format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute()
            )
        }
    }

    private func select(_ kind: TransactionKind) {
        if reduceMotion {
            draft.kind = kind
        } else {
            withAnimation(.snappy) {
                draft.kind = kind
            }
        }
    }

    // MARK: - 保存

    private func save(andContinue: Bool) {
        // 防重复提交：dismiss 动画期间连点保存会重复落库；成功关页不复位（页面将销毁）
        guard !isSaving else { return }
        isSaving = true
        draft.amountString = expression.finalizedDecimalString()
        do {
            let commands = TransactionCompositeService(context: modelContext)
            if let editingUUID {
                try commands.update(
                    uuid: editingUUID,
                    draft: draft,
                    tagUUIDs: selectedTagUUIDs,
                    isReimbursementMarked: draft.kind == .expense && isReimbursementMarked,
                    attachments: pendingAttachments
                )
                pendingAttachments.removeAll()
                dismiss()
                return
            }
            try commands.create(
                draft,
                ledgerID: ledgerID,
                tagUUIDs: selectedTagUUIDs,
                isReimbursementMarked: draft.kind == .expense && isReimbursementMarked,
                attachments: pendingAttachments
            )
            pendingAttachments.removeAll()
            if andContinue {
                expression = AmountExpression()
                draft.amountString = ""
                draft.note = ""
                isSaving = false // 保存再记：本笔已落库，放行下一笔
            } else {
                dismiss()
            }
        } catch {
            validationMessage = error.localizedDescription
            isSaving = false // 失败复位，允许改后重试
        }
    }

    private var isPresentingError: Binding<Bool> {
        Binding(
            get: { validationMessage != nil },
            set: { if !$0 { validationMessage = nil } }
        )
    }
}

private struct TransactionAdvancedOptionsView: View {
    @Binding var draft: TransactionDraft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("统计设置") {
                    Toggle("不计入预算", isOn: $draft.isExcludedFromBudget)
                        .zanzanControlSurface()
                    Toggle("不计入收支统计", isOn: $draft.isExcludedFromStats)
                        .zanzanControlSurface()
                }

                Section {
                    TextField("地点名称", text: $draft.locationName)
                    TextField("纬度", text: $draft.locationLatitudeString)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("经度", text: $draft.locationLongitudeString)
                        .keyboardType(.numbersAndPunctuation)
                } header: {
                    Text("记账位置")
                } footer: {
                    Text("地点名称、纬度和经度需同时填写；全部留空表示不记录位置。")
                }
            }
            .textFieldStyle(.zanzan)
            .zanzanCompactList()
            .zanzanSketchPageBackground()
            .navigationTitle("高级设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .buttonStyle(.glassProminent)
                }
            }
        }
    }
}
