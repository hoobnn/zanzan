import SwiftData
import SwiftUI

struct InstallmentSettlementView: View {
    let plan: InstallmentPlan
    let periodIndex: Int?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Account> { !$0.isSoftDeleted && !$0.isArchived && $0.isSelectableForRecord }, sort: \Account.sortOrder)
    private var accounts: [Account]
    @Query private var periods: [InstallmentPeriod]

    @State private var sourceAccountID: UUID?
    @State private var penaltyString = "0"
    @State private var settledAt = Date.now
    @State private var validationMessage: String?
    @State private var isSaving = false

    init(plan: InstallmentPlan, periodIndex: Int?) {
        self.plan = plan
        self.periodIndex = periodIndex
        let planID = plan.uuid
        _periods = Query(
            filter: #Predicate<InstallmentPeriod> {
                !$0.isSoftDeleted && $0.planID == planID
            },
            sort: \InstallmentPeriod.periodIndex
        )
    }

    private var debtAccount: Account? {
        accounts.first { $0.uuid == plan.accountID }
    }

    private var sourceAccounts: [Account] {
        accounts.filter {
            $0.uuid != plan.accountID && $0.currencyCode == debtAccount?.currencyCode
        }
    }

    private var isEarlySettlement: Bool { periodIndex == nil }

    private var currencyCode: String { debtAccount?.currencyCode ?? "CNY" }

    private var pendingPeriods: [InstallmentPeriod] {
        periods.filter { $0.status == .pending }
    }

    private var currentPeriod: InstallmentPeriod? {
        guard let periodIndex else { return nil }
        return periods.first { $0.periodIndex == periodIndex }
    }

    private var penaltyMinorUnits: Int {
        MoneyAmount.minorUnits(fromDecimalString: penaltyString) ?? 0
    }

    private var remainingPrincipalMinorUnits: Int {
        pendingPeriods.reduce(0) { $0 + $1.principalMinorUnits }
    }

    private var unpaidUpfrontChargeMinorUnits: Int {
        guard plan.chargeCollectionKind == .upfrontFirstPeriod else { return 0 }
        return pendingPeriods.first { $0.periodIndex == 1 }?.interestMinorUnits ?? 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(isEarlySettlement ? "提前结清" : "本期还款") {
                    Picker("还款账户", selection: $sourceAccountID) {
                        ForEach(sourceAccounts) { account in
                            Text(account.name).tag(account.uuid as UUID?)
                        }
                    }
                    .zanzanControlSurface()
                    DatePicker("还款时间", selection: $settledAt, in: DraftLimits.occurredAtPickerRange)
                        .zanzanControlSurface()
                    if isEarlySettlement {
                        TextField("违约金（可为 0）", text: $penaltyString)
                            .keyboardType(.decimalPad)
                    }
                }

                Section("扣款明细") {
                    if isEarlySettlement {
                        LabeledContent(
                            "剩余本金",
                            value: formatAmount(
                                remainingPrincipalMinorUnits,
                                currencyCode: currencyCode
                            )
                        )
                        if unpaidUpfrontChargeMinorUnits > 0 {
                            LabeledContent(
                                "未收首期息费",
                                value: formatAmount(
                                    unpaidUpfrontChargeMinorUnits,
                                    currencyCode: currencyCode
                                )
                            )
                        }
                        LabeledContent(
                            "违约金",
                            value: formatAmount(
                                penaltyMinorUnits,
                                currencyCode: currencyCode
                            )
                        )
                        LabeledContent(
                            "实际扣款",
                            value: formatAmount(
                                remainingPrincipalMinorUnits
                                    + unpaidUpfrontChargeMinorUnits
                                    + penaltyMinorUnits,
                                    currencyCode: currencyCode
                            )
                        )
                        .bold()
                    } else if let currentPeriod {
                        LabeledContent(
                            "本金",
                            value: formatAmount(
                                currentPeriod.principalMinorUnits,
                                currencyCode: currencyCode
                            )
                        )
                        LabeledContent(
                            "息费",
                            value: formatAmount(
                                currentPeriod.interestMinorUnits,
                                currencyCode: currencyCode
                            )
                        )
                        LabeledContent(
                            "实际扣款",
                            value: formatAmount(
                                currentPeriod.principalMinorUnits
                                    + currentPeriod.interestMinorUnits,
                                currencyCode: currencyCode
                            )
                        )
                        .bold()
                    }
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
            .navigationTitle(isEarlySettlement ? "提前结清" : "记一期")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                sourceAccountID = sourceAccountID ?? sourceAccounts.first?.uuid
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认") { save() }
                        .buttonStyle(.glassProminent)
                        .disabled(isSaving || sourceAccounts.isEmpty)
                }
            }
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        do {
            guard let sourceAccountID else { throw InstallmentServiceError.accountNotFound }
            let service = InstallmentService(context: modelContext)
            if let periodIndex {
                try service.settlePeriod(
                    planUUID: plan.uuid,
                    periodIndex: periodIndex,
                    fromAccountID: sourceAccountID,
                    at: settledAt
                )
            } else {
                guard let penalty = MoneyAmount.minorUnits(fromDecimalString: penaltyString) else {
                    throw InstallmentServiceError.negativePenalty
                }
                try service.settleEarly(
                    planUUID: plan.uuid,
                    fromAccountID: sourceAccountID,
                    penaltyMinorUnits: penalty,
                    at: settledAt
                )
            }
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
            isSaving = false
        }
    }
}
