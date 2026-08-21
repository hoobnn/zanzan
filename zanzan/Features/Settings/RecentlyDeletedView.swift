import SwiftData
import SwiftUI

struct RecentlyDeletedView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(filter: #Predicate<Ledger> { $0.isSoftDeleted }, sort: \Ledger.updatedAt, order: .reverse)
    private var ledgers: [Ledger]
    @Query(sort: \Account.updatedAt, order: .reverse)
    private var accounts: [Account]
    @Query(filter: #Predicate<Category> { $0.isSoftDeleted }, sort: \Category.updatedAt, order: .reverse)
    private var categories: [Category]
    @Query(filter: #Predicate<Tag> { $0.isSoftDeleted }, sort: \Tag.updatedAt, order: .reverse)
    private var tags: [Tag]
    @Query(filter: #Predicate<Budget> { $0.isSoftDeleted }, sort: \Budget.updatedAt, order: .reverse)
    private var budgets: [Budget]
    @Query(filter: #Predicate<CreditPool> { $0.isSoftDeleted }, sort: \CreditPool.updatedAt, order: .reverse)
    private var creditPools: [CreditPool]
    @Query(filter: #Predicate<RecurringRule> { $0.isSoftDeleted }, sort: \RecurringRule.updatedAt, order: .reverse)
    private var recurringRules: [RecurringRule]
    @Query(filter: #Predicate<InstallmentPlan> { $0.isSoftDeleted }, sort: \InstallmentPlan.updatedAt, order: .reverse)
    private var installmentPlans: [InstallmentPlan]
    @Query(filter: #Predicate<ImportBatch> { $0.isSoftDeleted }, sort: \ImportBatch.updatedAt, order: .reverse)
    private var importBatches: [ImportBatch]
    @Query(filter: #Predicate<Transaction> { $0.isSoftDeleted }, sort: \Transaction.updatedAt, order: .reverse)
    private var transactions: [Transaction]

    @State private var commandErrorMessage = ""
    @State private var isPresentingError = false

    private var deletedAccounts: [Account] {
        accounts.filter(\.isSoftDeleted)
    }

    /// ponytail: 软删集合通常很小，直接按 UUID + 时间戳匹配；达到数千项再建索引集合。
    private var rootCategories: [Category] {
        categories.filter { category in
            guard category.isSoftDeleted else { return false }
            guard let ledgerID = category.ledgerID else { return true }
            return !ledgers.contains {
                $0.uuid == ledgerID && $0.updatedAt == category.updatedAt
            }
        }
    }

    private var rootTags: [Tag] {
        tags.filter { tag in
            guard tag.isSoftDeleted else { return false }
            guard let ledgerID = tag.ledgerID else { return true }
            return !ledgers.contains {
                $0.uuid == ledgerID && $0.updatedAt == tag.updatedAt
            }
        }
    }

    private var rootBudgets: [Budget] {
        budgets.filter { budget in
            let cascadedByLedger = ledgers.contains {
                $0.uuid == budget.ledgerID && $0.updatedAt == budget.updatedAt
            }
            let cascadedByCategory = categories.contains { category in
                category.uuid == budget.categoryID
                    && category.updatedAt == budget.updatedAt
            }
            return !cascadedByLedger && !cascadedByCategory
        }
    }

    private var rootTransactions: [Transaction] {
        let deletedBatchIDs = Set(importBatches.map(\.uuid))
        return transactions.filter { transaction in
            guard transaction.sourceKind != .installment else { return false }
            guard transaction.sourceKind == .csvImport,
                  let batchID = transaction.sourceID else {
                return true
            }
            return !deletedBatchIDs.contains(batchID)
        }
    }

    private var isEmpty: Bool {
        ledgers.isEmpty
            && deletedAccounts.isEmpty
            && rootCategories.isEmpty
            && rootTags.isEmpty
            && rootBudgets.isEmpty
            && creditPools.isEmpty
            && recurringRules.isEmpty
            && installmentPlans.isEmpty
            && importBatches.isEmpty
            && rootTransactions.isEmpty
    }

    var body: some View {
        List {
            if !ledgers.isEmpty {
                Section("账本") {
                    ForEach(ledgers) { ledger in
                        RecentlyDeletedRow(
                            title: ledger.name,
                            detail: ledger.isArchived ? ZanzanLocalization.string("已归档") : "",
                            deletedAt: ledger.updatedAt,
                            systemImage: "books.vertical.fill",
                            accessibilityIdentifier: "recentlyDeleted.restore.ledger.\(ledger.uuid)",
                            restore: { restore(ledger) }
                        )
                    }
                }
            }

            if !deletedAccounts.isEmpty {
                Section("账户") {
                    ForEach(deletedAccounts) { account in
                        RecentlyDeletedRow(
                            title: account.name,
                            detail: account.subtitle,
                            deletedAt: account.updatedAt,
                            systemImage: "creditcard.fill",
                            accessibilityIdentifier: "recentlyDeleted.restore.account.\(account.uuid)",
                            isRestoreEnabled: account.kind != nil,
                            restore: { restore(account) }
                        )
                    }
                }
            }

            if !rootCategories.isEmpty {
                Section("分类") {
                    ForEach(rootCategories) { category in
                        RecentlyDeletedRow(
                            title: category.name,
                            detail: category.kind?.displayName ?? "",
                            deletedAt: category.updatedAt,
                            systemImage: "square.grid.2x2.fill",
                            accessibilityIdentifier: "recentlyDeleted.restore.category.\(category.uuid)",
                            isRestoreEnabled: category.kind != nil,
                            restore: { restore(category) }
                        )
                    }
                }
            }

            if !rootTags.isEmpty {
                Section("标签") {
                    ForEach(rootTags) { tag in
                        RecentlyDeletedRow(
                            title: tag.name,
                            detail: "",
                            deletedAt: tag.updatedAt,
                            systemImage: "tag.fill",
                            accessibilityIdentifier: "recentlyDeleted.restore.tag.\(tag.uuid)",
                            restore: { restore(tag) }
                        )
                    }
                }
            }

            if !rootBudgets.isEmpty {
                Section("预算") {
                    ForEach(rootBudgets) { budget in
                        RecentlyDeletedRow(
                            title: budgetTitle(budget),
                            detail: formatAmount(budget.amountMinorUnits),
                            deletedAt: budget.updatedAt,
                            systemImage: "gauge.with.dots.needle.33percent",
                            accessibilityIdentifier: "recentlyDeleted.restore.budget.\(budget.uuid)",
                            restore: { restore(budget) }
                        )
                    }
                }
            }

            if !creditPools.isEmpty {
                Section("授信池") {
                    ForEach(creditPools) { pool in
                        RecentlyDeletedRow(
                            title: pool.name,
                            detail: formatAmount(
                                pool.totalLimitMinorUnits,
                                currencyCode: pool.currencyCode
                            ),
                            deletedAt: pool.updatedAt,
                            systemImage: "creditcard.and.123",
                            accessibilityIdentifier: "recentlyDeleted.restore.creditPool.\(pool.uuid)",
                            restore: { restore(pool) }
                        )
                    }
                }
            }

            if !recurringRules.isEmpty {
                Section("周期记账") {
                    ForEach(recurringRules) { rule in
                        RecentlyDeletedRow(
                            title: rule.name,
                            detail: formatAmount(
                                rule.templateAmountMinorUnits,
                                currencyCode: currencyCode(forAccountID: rule.templateAccountID)
                            ),
                            deletedAt: rule.updatedAt,
                            systemImage: "repeat.circle.fill",
                            accessibilityIdentifier: "recentlyDeleted.restore.recurring.\(rule.uuid)",
                            restore: { restore(rule) }
                        )
                    }
                }
            }

            if !installmentPlans.isEmpty {
                Section("分期与贷款") {
                    ForEach(installmentPlans) { plan in
                        RecentlyDeletedRow(
                            title: plan.name,
                            detail: formatAmount(
                                plan.principalMinorUnits,
                                currencyCode: currencyCode(forAccountID: plan.accountID)
                            ),
                            deletedAt: plan.updatedAt,
                            systemImage: "calendar.badge.clock",
                            accessibilityIdentifier: "recentlyDeleted.restore.installment.\(plan.uuid)",
                            restore: { restore(plan) }
                        )
                    }
                }
            }

            if !importBatches.isEmpty {
                Section("导入历史") {
                    ForEach(importBatches) { batch in
                        RecentlyDeletedRow(
                            title: batch.fileName,
                            detail: ZanzanLocalization.string(
                                "\(batch.transactionCount) 笔 · \(ZanzanLocalization.formatted(batch.importedAt, date: .abbreviated, time: .shortened))"
                            ),
                            deletedAt: batch.updatedAt,
                            systemImage: "doc.badge.arrow.up",
                            accessibilityIdentifier: "recentlyDeleted.restore.importBatch.\(batch.uuid)",
                            restore: { restore(batch) }
                        )
                    }
                }
            }

            if !rootTransactions.isEmpty {
                Section("流水") {
                    ForEach(rootTransactions) { transaction in
                        RecentlyDeletedRow(
                            title: transactionTitle(transaction),
                            detail: transactionDetail(transaction),
                            deletedAt: transaction.updatedAt,
                            systemImage: transactionSystemImage(transaction),
                            accessibilityIdentifier: "recentlyDeleted.restore.transaction.\(transaction.uuid)",
                            isRestoreEnabled: canRestore(transaction),
                            restore: { restore(transaction) }
                        )
                    }
                }
            }
        }
        .overlay {
            if isEmpty {
                ContentUnavailableView(
                    "最近没有删除的项目",
                    systemImage: "trash",
                    description: Text("删除的项目会显示在这里，可在需要时逐项恢复")
                )
            }
        }
        .accessibilityIdentifier("screen.recentlyDeleted")
        .zanzanCompactList()
        .zanzanSketchPageBackground()
        .navigationTitle("最近删除")
        .alert("操作失败", isPresented: $isPresentingError) { } message: {
            Text(commandErrorMessage)
        }
    }

    private func budgetTitle(_ budget: Budget) -> String {
        guard let year = budget.periodYear, let month = budget.periodMonth else {
            return ZanzanLocalization.string("默认预算")
        }
        return ZanzanLocalization.string("\(year) 年 \(month) 月预算")
    }

    private func currencyCode(forAccountID accountID: UUID?) -> String {
        guard let accountID else { return FxConversion.baseCurrencyCode }
        return accounts.first { $0.uuid == accountID }?.currencyCode
            ?? FxConversion.baseCurrencyCode
    }

    private func transactionTitle(_ transaction: Transaction) -> String {
        if !transaction.note.isEmpty {
            return transaction.note
        }
        return transaction.kind?.displayName ?? ZanzanLocalization.string("未知类型流水")
    }

    private func transactionDetail(_ transaction: Transaction) -> String {
        let amount = formatAmount(
            transaction.amountMinorUnits,
            currencyCode: transaction.currencyCode
        )
        let occurredAt = ZanzanLocalization.formatted(
            transaction.occurredAt,
            date: .abbreviated,
            time: .omitted
        )
        let detail = "\(transaction.kind?.displayName ?? ZanzanLocalization.string("未知类型流水")) · \(amount) · \(occurredAt)"
        guard canRestore(transaction) else {
            return "\(detail) · \(ZanzanLocalization.string("需要升级 App 后恢复"))"
        }
        return detail
    }

    private func transactionSystemImage(_ transaction: Transaction) -> String {
        switch transaction.kind {
        case .expense: "arrow.up.circle.fill"
        case .income: "arrow.down.circle.fill"
        case .transfer: "arrow.left.arrow.right.circle.fill"
        case nil: "questionmark.circle.fill"
        }
    }

    private func canRestore(_ transaction: Transaction) -> Bool {
        transaction.kind != nil
            && transaction.sourceKind != nil
            && (
                transaction.settlementKindRawValue.isEmpty
                    || transaction.settlementKind != nil
            )
    }

    private func restore(_ ledger: Ledger) {
        run { try LedgerService(context: modelContext).undoSoftDeleteLedger(uuid: ledger.uuid) }
    }

    private func restore(_ account: Account) {
        run { try AccountService(context: modelContext).undoSoftDeleteAccount(uuid: account.uuid) }
    }

    private func restore(_ category: Category) {
        run { try CategoryService(context: modelContext).undoSoftDeleteCategory(uuid: category.uuid) }
    }

    private func restore(_ tag: Tag) {
        run { try TagService(context: modelContext).undoSoftDeleteTag(uuid: tag.uuid) }
    }

    private func restore(_ budget: Budget) {
        run { try BudgetService(context: modelContext).undoSoftDeleteBudget(uuid: budget.uuid) }
    }

    private func restore(_ pool: CreditPool) {
        run { try CreditPoolService(context: modelContext).undoSoftDeletePool(uuid: pool.uuid) }
    }

    private func restore(_ rule: RecurringRule) {
        run {
            try RecurringRuleService(context: modelContext)
                .undoSoftDeleteRule(uuid: rule.uuid, asOf: .now)
        }
    }

    private func restore(_ plan: InstallmentPlan) {
        run {
            try InstallmentService(context: modelContext)
                .undoSoftDeletePlan(uuid: plan.uuid, at: .now)
        }
    }

    private func restore(_ batch: ImportBatch) {
        run {
            try TransactionCSVImporter(context: modelContext)
                .restoreBatch(batchUUID: batch.uuid)
        }
    }

    private func restore(_ transaction: Transaction) {
        run {
            if transaction.settlementKindRawValue.isEmpty {
                try TransactionService(context: modelContext)
                    .undoSoftDeleteTransaction(uuid: transaction.uuid)
            } else {
                try ReimbursementService(context: modelContext)
                    .restoreSettlement(transactionUUID: transaction.uuid)
            }
        }
    }

    private func run(_ command: () throws -> Void) {
        do {
            try command()
        } catch {
            commandErrorMessage = error.localizedDescription
            isPresentingError = true
        }
    }
}
