import SwiftData
import SwiftUI

struct AccountDetailView: View {
    let account: Account

    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Transaction> { !$0.isSoftDeleted })
    private var transactions: [Transaction]

    @State private var isEditing = false
    @State private var isCalibrating = false
    @State private var isRepaying = false

    private var balanceResult: Result<Int, Error> {
        _ = transactions.count
        return Result {
            try AccountBalanceProvider(context: modelContext).balanceMinorUnits(of: account)
        }
    }

    private var statementResult: Result<CreditCardStatement, Error>? {
        guard account.kind == .credit else { return nil }
        _ = transactions.count
        return Result {
            try CreditCardStatementProvider(context: modelContext).statement(for: account)
        }
    }

    var body: some View {
        List {
            balanceCard
            if let statementResult {
                creditSection(statementResult)
            }

            Section("账户信息") {
                LabeledContent("类型", value: (account.kind ?? .fund).displayName)
                LabeledContent("币种", value: account.currencyCode)
                if !account.subtitle.isEmpty {
                    LabeledContent("机构", value: account.subtitle)
                }
                LabeledContent("计入净资产", value: account.isIncludedInNetWorth ? ZanzanLocalization.string( "是") : ZanzanLocalization.string( "否"))
                if !account.note.isEmpty {
                    LabeledContent("备注", value: account.note)
                }
            }

            if !account.isArchived && account.isSelectableForRecord {
                Section("操作") {
                    Button("校准到实际余额", systemImage: "scope") {
                        isCalibrating = true
                    }
                    if account.kind == .credit {
                        Button("信用卡还款", systemImage: "arrow.left.arrow.right") {
                            isRepaying = true
                        }
                    }
                }
            }
        }
        .zanzanCompactList()
        .zanzanSketchPageBackground()
        .navigationTitle(account.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("编辑", systemImage: "pencil") {
                    isEditing = true
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            AccountFormView(title: ZanzanLocalization.string( "编辑账户"), draft: AccountDraft(account: account)) { draft in
                try AccountService(context: modelContext).updateAccount(uuid: account.uuid, draft: draft)
            }
        }
        .sheet(isPresented: $isCalibrating) {
            BalanceCalibrationView(account: account) { actual, date, rate in
                try AccountService(context: modelContext).calibrateBalance(
                    accountUUID: account.uuid,
                    actualBalanceMinorUnits: actual,
                    occurredAt: date,
                    fxRateToBase: rate
                )
            }
        }
        .sheet(isPresented: $isRepaying) {
            CreditCardRepaymentView(card: account)
        }
    }

    private var balanceCard: some View {
        Section {
            HStack(spacing: 12) {
                AccountIconView(account: account, size: 48)
                VStack(alignment: .leading, spacing: 8) {
                    Text("当前余额")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    switch balanceResult {
                    case let .success(balance):
                        Text(formatAmount(balance, currencyCode: account.currencyCode))
                            .font(.system(.title, design: .rounded, weight: .bold))
                            .monospacedDigit()
                    case let .failure(error):
                        Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .zanzanSketchCard(tint: .zanzanMint)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private func creditSection(_ result: Result<CreditCardStatement, Error>) -> some View {
        Section("本期账单") {
            switch result {
            case let .success(statement):
                LabeledContent("账单周期") {
                    Text(
                        "\(ZanzanLocalization.formatted(statement.periodStart, date: .abbreviated, time: .omitted)) – \(ZanzanLocalization.formatted(statement.periodEndExclusive.addingTimeInterval(-1), date: .abbreviated, time: .omitted))"
                    )
                }
                LabeledContent(
                    "本期账单",
                    value: formatAmount(
                        statement.statementAmountMinorUnits,
                        currencyCode: account.currencyCode
                    )
                )
                if let available = statement.availableCreditMinorUnits {
                    LabeledContent(
                        "剩余额度",
                        value: formatAmount(available, currencyCode: account.currencyCode)
                    )
                }
                if let dueDay = account.paymentDueDay {
                    LabeledContent("还款日", value: ZanzanLocalization.string( "每月 \(dueDay) 日"))
                }
            case let .failure(error):
                Label(error.localizedDescription, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
