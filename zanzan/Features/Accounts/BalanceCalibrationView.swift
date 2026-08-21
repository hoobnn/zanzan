import SwiftUI

struct BalanceCalibrationView: View {
    let account: Account
    let onSave: (Int, Date, Decimal?) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var actualBalanceString = ""
    @State private var occurredAt = Date.now
    @State private var fxRateString = ""
    @State private var validationMessage: String?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("实际余额") {
                    TextField("当前实际余额", text: $actualBalanceString)
                        .keyboardType(.numbersAndPunctuation)
                    DatePicker("校准时间", selection: $occurredAt, in: DraftLimits.occurredAtPickerRange)
                        .zanzanControlSurface()
                }

                if account.currencyCode != FxConversion.baseCurrencyCode {
                    Section("汇率") {
                        TextField("1 \(account.currencyCode) = ? CNY", text: $fxRateString)
                            .keyboardType(.decimalPad)
                    }
                }

                Section {
                    Text("系统会按差额生成一笔不计入收支统计的校准流水，既有流水不会被改写。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
            .navigationTitle("校准余额")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("校准") { save() }
                        .buttonStyle(.glassProminent)
                        .disabled(isSaving)
                }
            }
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        do {
            guard let actual = MoneyAmount.signedMinorUnits(fromDecimalString: actualBalanceString) else {
                throw AccountDraftError.invalidInitialBalance
            }
            let rate: Decimal?
            if fxRateString.trimmingCharacters(in: .whitespaces).isEmpty {
                rate = nil
            } else {
                guard let parsed = MoneyAmount.strictDecimal(from: fxRateString), parsed > 0 else {
                    throw TransactionDraftError.invalidFxRate
                }
                rate = parsed
            }
            try onSave(actual, occurredAt, rate)
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
            isSaving = false
        }
    }
}
