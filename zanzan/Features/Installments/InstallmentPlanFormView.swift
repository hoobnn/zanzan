import SwiftData
import SwiftUI

struct InstallmentPlanFormView: View {
    let onSave: (InstallmentPlanDraft) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(
        filter: #Predicate<Ledger> { !$0.isSoftDeleted && !$0.isArchived },
        sort: \Ledger.sortOrder
    )
    private var ledgers: [Ledger]
    @Query(
        filter: #Predicate<Account> {
            !$0.isSoftDeleted && !$0.isArchived && $0.isSelectableForRecord
        },
        sort: \Account.sortOrder
    )
    private var accounts: [Account]

    @State private var name = ""
    @State private var kind = InstallmentPlanKind.purchase
    @State private var accountID: UUID?
    @State private var ledgerID: UUID?
    @State private var principalString = ""
    @State private var totalPeriodsString = ""
    @State private var amortizationKind = AmortizationKind.flatFee
    @State private var annualRatePercentString = ""
    @State private var totalChargeString = ""
    @State private var calculationPreset = InstallmentCalculationPreset.standard
    @State private var chargeCollectionKind = ChargeCollectionKind.perPeriod
    @State private var principalRoundingKind = InstallmentRoundingKind.downToMinorUnit
    @State private var principalRemainderKind = InstallmentRemainderKind.lastPeriod
    @State private var chargeRoundingKind = InstallmentRoundingKind.downToMinorUnit
    @State private var chargeRemainderKind = InstallmentRemainderKind.lastPeriod
    @State private var isShowingCalculationRules = false
    @State private var firstDueAt = Date.now
    @State private var note = ""
    @State private var customPrincipalStrings: [String] = []
    @State private var customInterestStrings: [String] = []
    @State private var validationMessage: String?
    @State private var isSaving = false

    private var debtAccounts: [Account] {
        let expected: AccountKind = kind == .loan ? .payable : .credit
        return accounts.filter { $0.kind == expected }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("计划") {
                    TextField("计划名称", text: $name)
                    Picker("类型", selection: $kind) {
                        Text("消费分期").tag(InstallmentPlanKind.purchase)
                        Text("账单分期").tag(InstallmentPlanKind.statement)
                        Text("贷款").tag(InstallmentPlanKind.loan)
                    }
                    .zanzanControlSurface()
                    .onChange(of: kind) {
                        if !debtAccounts.contains(where: { $0.uuid == accountID }) {
                            accountID = debtAccounts.first?.uuid
                        }
                    }
                    Picker("债务账户", selection: $accountID) {
                        ForEach(debtAccounts) { account in
                            Text(account.name).tag(account.uuid as UUID?)
                        }
                    }
                    .zanzanControlSurface()
                    Picker("账本", selection: $ledgerID) {
                        ForEach(ledgers) { ledger in
                            Text(ledger.name).tag(ledger.uuid as UUID?)
                        }
                    }
                    .zanzanControlSurface()
                    TextField("本金总额", text: $principalString)
                        .keyboardType(.decimalPad)
                    TextField("总期数", text: $totalPeriodsString)
                        .keyboardType(.numberPad)
                        .onChange(of: totalPeriodsString) { resizeCustomPeriods() }
                    DatePicker("首期还款日", selection: $firstDueAt, in: DraftLimits.occurredAtPickerRange)
                        .zanzanControlSurface()

                    if debtAccounts.isEmpty {
                        Label("请先创建匹配类型的债务账户", systemImage: "creditcard.trianglebadge.exclamationmark")
                            .foregroundStyle(.secondary)
                    }
                    if ledgers.isEmpty {
                        Label("请先创建账本", systemImage: "books.vertical")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("还款方式") {
                    Picker("方式", selection: $amortizationKind) {
                        Text("固定手续费").tag(AmortizationKind.flatFee)
                        Text("等额本息").tag(AmortizationKind.annuity)
                        Text("等额本金").tag(AmortizationKind.linearPrincipal)
                        Text("先息后本").tag(AmortizationKind.interestOnly)
                        Text("自定义").tag(AmortizationKind.custom)
                    }
                    .zanzanControlSurface()
                    if amortizationKind == .annuity
                        || amortizationKind == .linearPrincipal
                        || amortizationKind == .interestOnly {
                        TextField("年利率（%）", text: $annualRatePercentString)
                            .keyboardType(.decimalPad)
                    } else if amortizationKind == .flatFee {
                        TextField("息费总额", text: $totalChargeString)
                            .keyboardType(.decimalPad)
                        Picker("息费收取方式", selection: $chargeCollectionKind) {
                            Text("分期收取").tag(ChargeCollectionKind.perPeriod)
                            Text("首期一次收取").tag(ChargeCollectionKind.upfrontFirstPeriod)
                        }
                        .zanzanControlSurface()
                    }
                }

                if amortizationKind == .flatFee {
                    Section {
                        DisclosureGroup("计算规则", isExpanded: $isShowingCalculationRules) {
                            Picker("银行规则预设", selection: $calculationPreset) {
                                ForEach(InstallmentCalculationPreset.allCases) { preset in
                                    Text(ZanzanLocalization.string(preset.title)).tag(preset)
                                }
                            }
                            .zanzanControlSurface()
                            .onChange(of: calculationPreset) {
                                applyPreset(calculationPreset)
                            }

                            Text(
                                ZanzanLocalization.string(
                                    calculationPreset.productScopeNote
                                )
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                            if let sourceURL = calculationPreset.sourceURL {
                                Link(destination: sourceURL) {
                                    Label(
                                        "查看官方规则来源",
                                        systemImage: "arrow.up.right.square"
                                    )
                                }
                                .font(.footnote)
                            }

                            Picker("本金取整", selection: $principalRoundingKind) {
                                roundingOptions
                            }
                            .zanzanControlSurface()
                            Picker("本金尾差", selection: $principalRemainderKind) {
                                remainderOptions
                            }
                            .zanzanControlSurface()

                            if chargeCollectionKind == .perPeriod {
                                Picker("息费取整", selection: $chargeRoundingKind) {
                                    roundingOptions
                                }
                                .zanzanControlSurface()
                                Picker("息费尾差", selection: $chargeRemainderKind) {
                                    remainderOptions
                                }
                                .zanzanControlSurface()
                            }
                        }
                        .zanzanControlSurface()
                    } footer: {
                        Text("预设仅套用公开的计算规则，不包含费率或息费金额；请以合同或账单为准，保存前可逐项调整。")
                    }
                }

                if amortizationKind == .custom {
                    Section("逐期本息") {
                        ForEach(customPrincipalStrings.indices, id: \.self) { index in
                            VStack(alignment: .leading) {
                                Text("第 \(index + 1) 期")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    TextField("本金", text: stringBinding($customPrincipalStrings, at: index))
                                        .keyboardType(.decimalPad)
                                    TextField("利息", text: stringBinding($customInterestStrings, at: index))
                                        .keyboardType(.decimalPad)
                                }
                            }
                        }
                    }
                }

                Section("备注") {
                    TextField("可选", text: $note)
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .textFieldStyle(.zanzan)
            .zanzanCompactList()
            .zanzanSketchPageBackground()
            .navigationTitle("新建分期计划")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                ledgerID = ledgerID ?? ledgers.first(where: \.isDefault)?.uuid ?? ledgers.first?.uuid
                accountID = accountID ?? debtAccounts.first?.uuid
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .buttonStyle(.glassProminent)
                        .disabled(isSaving || debtAccounts.isEmpty || ledgers.isEmpty)
                }
            }
        }
    }

    private func stringBinding(_ array: Binding<[String]>, at index: Int) -> Binding<String> {
        Binding(
            get: { array.wrappedValue.indices.contains(index) ? array.wrappedValue[index] : "" },
            set: { value in
                guard array.wrappedValue.indices.contains(index) else { return }
                array.wrappedValue[index] = value
            }
        )
    }

    private func resizeCustomPeriods() {
        let count = min(max(Int(totalPeriodsString) ?? 0, 0), DraftLimits.maxInstallmentPeriods)
        if customPrincipalStrings.count < count {
            customPrincipalStrings += Array(repeating: "", count: count - customPrincipalStrings.count)
            customInterestStrings += Array(repeating: "", count: count - customInterestStrings.count)
        } else if customPrincipalStrings.count > count {
            customPrincipalStrings.removeLast(customPrincipalStrings.count - count)
            customInterestStrings.removeLast(customInterestStrings.count - count)
        }
    }

    @ViewBuilder
    private var roundingOptions: some View {
        Text("向下精确到分").tag(InstallmentRoundingKind.downToMinorUnit)
        Text("四舍五入到分").tag(InstallmentRoundingKind.nearestMinorUnit)
        Text("四舍五入到元").tag(InstallmentRoundingKind.nearestMajorUnit)
    }

    @ViewBuilder
    private var remainderOptions: some View {
        Text("归首期").tag(InstallmentRemainderKind.firstPeriod)
        Text("归末期").tag(InstallmentRemainderKind.lastPeriod)
    }

    private func applyPreset(_ preset: InstallmentCalculationPreset) {
        let rules = preset.rules
        chargeCollectionKind = rules.chargeCollectionKind
        principalRoundingKind = rules.principalRoundingKind
        principalRemainderKind = rules.principalRemainderKind
        chargeRoundingKind = rules.chargeRoundingKind
        chargeRemainderKind = rules.chargeRemainderKind
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        do {
            guard let principal = MoneyAmount.minorUnits(fromDecimalString: principalString) else {
                throw InstallmentPlanDraftError.nonPositivePrincipal
            }
            let periods = Int(totalPeriodsString) ?? 0
            var draft = InstallmentPlanDraft(firstDueAt: firstDueAt)
            draft.name = name
            draft.kind = kind
            draft.accountID = accountID
            draft.ledgerID = ledgerID
            draft.principalMinorUnits = principal
            draft.totalPeriods = periods
            draft.amortizationKind = amortizationKind
            draft.note = note

            if amortizationKind == .annuity
                || amortizationKind == .linearPrincipal
                || amortizationKind == .interestOnly {
                guard let rate = MoneyAmount.strictDecimal(from: annualRatePercentString), rate >= 0 else {
                    throw InstallmentPlanDraftError.missingAnnualRate
                }
                var bps = rate * 100
                var roundedBps = Decimal()
                NSDecimalRound(&roundedBps, &bps, 0, .plain)
                guard bps == roundedBps, bps <= Decimal(DraftLimits.maxAnnualRateBps) else {
                    throw InstallmentPlanDraftError.annualRateTooHigh
                }
                draft.annualRateBps = (bps as NSDecimalNumber).intValue
            } else if amortizationKind == .flatFee {
                guard let totalCharge = MoneyAmount.minorUnits(fromDecimalString: totalChargeString) else {
                    throw InstallmentPlanDraftError.missingFlatFee
                }
                draft.totalChargeMinorUnits = totalCharge
                draft.chargeCollectionKind = chargeCollectionKind
                draft.principalRoundingKind = principalRoundingKind
                draft.principalRemainderKind = principalRemainderKind
                draft.chargeRoundingKind = chargeRoundingKind
                draft.chargeRemainderKind = chargeRemainderKind
            } else if amortizationKind == .custom {
                draft.customPeriods = try customPrincipalStrings.indices.map { index in
                    guard let principal = MoneyAmount.minorUnits(fromDecimalString: customPrincipalStrings[index]),
                          let interest = MoneyAmount.minorUnits(fromDecimalString: customInterestStrings[index]) else {
                        throw InstallmentPlanDraftError.invalidCustomPeriod
                    }
                    return InstallmentPlanDraft.CustomPeriodInput(
                        principalMinorUnits: principal,
                        interestMinorUnits: interest
                    )
                }
            }
            try onSave(draft)
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
            isSaving = false
        }
    }
}
