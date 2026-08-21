import Foundation
import SwiftData
import Testing
@testable import zanzan

@MainActor
struct FullBackupAllModelsTests {
    private struct Fixture {
        let context: ModelContext
        let attachmentDirectory: URL
        let safetyBackupURL: URL
        let temporaryDirectory: URL

        func tearDown() {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    private func makeFixture() throws -> Fixture {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "FullBackupAllModelsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        return Fixture(
            context: ModelContext(try AppModelContainer.make(inMemory: true)),
            attachmentDirectory: temporaryDirectory
                .appending(path: "Attachments", directoryHint: .isDirectory),
            safetyBackupURL: temporaryDirectory
                .appending(path: "PreRestore.zanzanbackup", directoryHint: .isDirectory),
            temporaryDirectory: temporaryDirectory
        )
    }

    @Test func 十四模型经公开备份接口往返后字节与高风险字段不变() throws {
        let source = try makeFixture()
        defer { source.tearDown() }

        let baseDate = Date(timeIntervalSince1970: 1_735_689_600.125)
        let nextDate = Date(timeIntervalSince1970: 1_738_368_000.250)
        let dueDate = Date(timeIntervalSince1970: 1_740_960_000.375)
        let closedDate = Date(timeIntervalSince1970: 1_743_379_200.500)
        let manifestCreatedAt = Date(timeIntervalSince1970: 1_800_000_000.625)
        let transactionRate = try #require(Decimal(string: "7.23456789"))
        let snapshotRate = try #require(Decimal(string: "7.19876543"))

        let ledger = Ledger(name: "全模型账本")
        ledger.isDefault = true
        ledger.iconKindRawValue = IconDescriptor.Kind.emoji.rawValue
        ledger.iconPrimary = "🧪"
        ledger.colorID = "purple"

        let creditPool = CreditPool(name: "共享授信", totalLimitMinorUnits: 500_000)
        creditPool.currencyCode = "USD"
        creditPool.note = "全模型测试授信池"

        let usdAccount = Account(name: "美元现金", kind: .fund)
        usdAccount.currencyCode = "USD"
        usdAccount.initialBalanceMinorUnits = 88_800

        let creditAccount = Account(name: "信用卡", kind: .credit)
        creditAccount.currencyCode = "USD"
        creditAccount.creditPoolID = creditPool.uuid
        creditAccount.creditLimitMinorUnits = 100_000
        creditAccount.statementDay = 8
        creditAccount.paymentDueDay = 26

        let expenseParent = Category(name: "生活", kind: .expense, sortOrder: 1)
        expenseParent.ledgerID = ledger.uuid
        let expenseChild = Category(name: "交通", kind: .expense, sortOrder: 2)
        expenseChild.parentID = expenseParent.uuid
        expenseChild.ledgerID = ledger.uuid
        let incomeCategory = Category(name: "其他收入", kind: .income, sortOrder: 3)
        incomeCategory.ledgerID = ledger.uuid

        let tag = Tag(name: "全模型")
        tag.colorID = "orange"
        tag.ledgerID = ledger.uuid

        let importBatch = ImportBatch(fileName: "all-models.csv", importedAt: baseDate)
        importBatch.contentHash = String(repeating: "ab", count: 32)
        importBatch.transactionCount = 1

        let recurringRule = RecurringRule(
            name: "周期入账",
            frequency: .monthly,
            startAt: baseDate,
            nextRunAt: dueDate,
            templateKind: .income,
            templateAmountMinorUnits: 5_000
        )
        recurringRule.interval = 2
        recurringRule.recurrenceDays = [5, 25]
        recurringRule.endAt = closedDate
        recurringRule.templateLedgerID = ledger.uuid
        recurringRule.templateAccountID = usdAccount.uuid
        recurringRule.templateCategoryID = incomeCategory.uuid
        recurringRule.templateTagIDs = [tag.uuid]
        recurringRule.templateNote = "周期来源链路"

        let installmentPlan = InstallmentPlan(
            name: "账单分期",
            kind: .statement,
            accountID: creditAccount.uuid,
            ledgerID: ledger.uuid,
            principalMinorUnits: 10_000,
            totalPeriods: 1,
            amortizationKind: .flatFee,
            firstDueAt: dueDate
        )
        installmentPlan.totalChargeMinorUnits = 1_200
        installmentPlan.chargeCollectionKindRawValue =
            ChargeCollectionKind.upfrontFirstPeriod.rawValue
        installmentPlan.principalRoundingKindRawValue =
            InstallmentRoundingKind.nearestMajorUnit.rawValue
        installmentPlan.principalRemainderKindRawValue =
            InstallmentRemainderKind.firstPeriod.rawValue
        installmentPlan.chargeRoundingKindRawValue =
            InstallmentRoundingKind.nearestMinorUnit.rawValue
        installmentPlan.chargeRemainderKindRawValue =
            InstallmentRemainderKind.firstPeriod.rawValue
        installmentPlan.statusRawValue = InstallmentPlanStatus.completed.rawValue
        installmentPlan.closedAt = closedDate
        installmentPlan.note = "覆盖 SchemaV2 字段"

        let importedTransaction = Transaction(
            kind: .expense,
            amountMinorUnits: 12_345,
            occurredAt: baseDate,
            ledgerID: ledger.uuid
        )
        importedTransaction.account = usdAccount
        importedTransaction.category = expenseChild
        importedTransaction.tags = [tag]
        importedTransaction.currencyCode = "USD"
        importedTransaction.fxRateToBase = transactionRate
        importedTransaction.sourceKindRawValue = TransactionSourceKind.csvImport.rawValue
        importedTransaction.sourceID = importBatch.uuid
        importedTransaction.reimbursementStatusRawValue =
            ReimbursementStatus.waiting.rawValue

        let recurringTransaction = Transaction(
            kind: .income,
            amountMinorUnits: 5_000,
            occurredAt: nextDate,
            ledgerID: ledger.uuid
        )
        recurringTransaction.account = usdAccount
        recurringTransaction.category = incomeCategory
        recurringTransaction.tags = [tag]
        recurringTransaction.currencyCode = "USD"
        recurringTransaction.fxRateToBase = transactionRate
        recurringTransaction.sourceKindRawValue = TransactionSourceKind.recurring.rawValue
        recurringTransaction.sourceID = recurringRule.uuid
        recurringTransaction.settlementKindRawValue =
            TransactionLinkKind.reimbursement.rawValue

        let installmentTransaction = Transaction(
            kind: .transfer,
            amountMinorUnits: 10_000,
            occurredAt: dueDate,
            ledgerID: ledger.uuid
        )
        installmentTransaction.account = usdAccount
        installmentTransaction.targetAccount = creditAccount
        installmentTransaction.currencyCode = "USD"
        installmentTransaction.fxRateToBase = transactionRate
        installmentTransaction.feeMinorUnits = 1_200
        installmentTransaction.sourceKindRawValue =
            TransactionSourceKind.installment.rawValue
        installmentTransaction.sourceID = installmentPlan.uuid

        let transactionLink = TransactionLink(
            originalTransactionID: importedTransaction.uuid,
            settlementTransactionID: recurringTransaction.uuid,
            kind: .reimbursement,
            amountMinorUnits: 5_000
        )

        let budget = Budget(ledgerID: ledger.uuid, amountMinorUnits: 80_000)
        budget.categoryID = expenseParent.uuid
        budget.periodYear = 2026
        budget.periodMonth = 7
        budget.isSoftDeleted = true

        let installmentPeriod = InstallmentPeriod(
            planID: installmentPlan.uuid,
            periodIndex: 1,
            dueAt: dueDate,
            principalMinorUnits: 10_000,
            interestMinorUnits: 1_200
        )
        installmentPeriod.statusRawValue = InstallmentPeriodStatus.settled.rawValue
        installmentPeriod.settledAt = closedDate
        installmentPeriod.settledTransactionID = installmentTransaction.uuid

        let balanceSnapshot = BalanceSnapshot(
            accountID: usdAccount.uuid,
            snapshotAt: nextDate,
            balanceMinorUnits: 76_455
        )
        balanceSnapshot.fxRateToBase = snapshotRate

        let auditLog = AuditLog(action: "fullBackupRoundTrip", detail: "覆盖十四模型")
        auditLog.occurredAt = closedDate
        auditLog.isSoftDeleted = true

        source.context.insert(ledger)
        source.context.insert(creditPool)
        source.context.insert(usdAccount)
        source.context.insert(creditAccount)
        source.context.insert(expenseParent)
        source.context.insert(expenseChild)
        source.context.insert(incomeCategory)
        source.context.insert(tag)
        source.context.insert(importBatch)
        source.context.insert(recurringRule)
        source.context.insert(installmentPlan)
        source.context.insert(importedTransaction)
        source.context.insert(recurringTransaction)
        source.context.insert(installmentTransaction)
        source.context.insert(transactionLink)
        source.context.insert(budget)
        source.context.insert(installmentPeriod)
        source.context.insert(balanceSnapshot)
        source.context.insert(auditLog)
        try source.context.zanzanSave()

        let attachmentData = Data("all-models-receipt".utf8)
        let attachmentFileName = try AttachmentStore(
            context: source.context,
            rootDirectory: source.attachmentDirectory
        ).save(data: attachmentData, for: importedTransaction.uuid)

        let originalPackage = try FullBackupService(
            context: source.context,
            attachmentRootDirectory: source.attachmentDirectory,
            safetyBackupURL: source.safetyBackupURL
        ).export(createdAt: manifestCreatedAt)

        let target = try makeFixture()
        defer { target.tearDown() }
        let targetService = FullBackupService(
            context: target.context,
            attachmentRootDirectory: target.attachmentDirectory,
            safetyBackupURL: target.safetyBackupURL
        )
        let summary = try targetService.restore(
            originalPackage,
            createsSafetyBackup: false
        )
        let reexportedPackage = try targetService.export(createdAt: manifestCreatedAt)

        #expect(summary.recordCount == 19)
        #expect(summary.attachmentCount == 1)
        #expect(reexportedPackage.manifest == originalPackage.manifest)
        #expect(reexportedPackage.attachments == originalPackage.attachments)
        #expect(reexportedPackage.attachments[attachmentFileName] == attachmentData)

        let counts = [
            try target.context.fetchCount(FetchDescriptor<Ledger>()),
            try target.context.fetchCount(FetchDescriptor<Account>()),
            try target.context.fetchCount(FetchDescriptor<Category>()),
            try target.context.fetchCount(FetchDescriptor<Transaction>()),
            try target.context.fetchCount(FetchDescriptor<Tag>()),
            try target.context.fetchCount(FetchDescriptor<TransactionLink>()),
            try target.context.fetchCount(FetchDescriptor<Budget>()),
            try target.context.fetchCount(FetchDescriptor<CreditPool>()),
            try target.context.fetchCount(FetchDescriptor<InstallmentPlan>()),
            try target.context.fetchCount(FetchDescriptor<InstallmentPeriod>()),
            try target.context.fetchCount(FetchDescriptor<RecurringRule>()),
            try target.context.fetchCount(FetchDescriptor<ImportBatch>()),
            try target.context.fetchCount(FetchDescriptor<BalanceSnapshot>()),
            try target.context.fetchCount(FetchDescriptor<AuditLog>()),
        ]
        #expect(counts == [1, 2, 3, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1])

        let restoredAccounts = Dictionary(
            uniqueKeysWithValues: try target.context.fetch(FetchDescriptor<Account>())
                .map { ($0.uuid, $0) }
        )
        let restoredCategories = Dictionary(
            uniqueKeysWithValues: try target.context.fetch(FetchDescriptor<Category>())
                .map { ($0.uuid, $0) }
        )
        let restoredTransactions = Dictionary(
            uniqueKeysWithValues: try target.context.fetch(FetchDescriptor<Transaction>())
                .map { ($0.uuid, $0) }
        )
        let restoredCreditAccount = try #require(restoredAccounts[creditAccount.uuid])
        let restoredExpenseChild = try #require(restoredCategories[expenseChild.uuid])
        let restoredImported = try #require(restoredTransactions[importedTransaction.uuid])
        let restoredRecurring = try #require(restoredTransactions[recurringTransaction.uuid])
        let restoredInstallment = try #require(
            restoredTransactions[installmentTransaction.uuid]
        )
        let restoredPlans = try target.context.fetch(FetchDescriptor<InstallmentPlan>())
        let restoredPeriods = try target.context.fetch(FetchDescriptor<InstallmentPeriod>())
        let restoredRules = try target.context.fetch(FetchDescriptor<RecurringRule>())
        let restoredLinks = try target.context.fetch(FetchDescriptor<TransactionLink>())
        let restoredBudgets = try target.context.fetch(FetchDescriptor<Budget>())
        let restoredSnapshots = try target.context.fetch(FetchDescriptor<BalanceSnapshot>())
        let restoredAudits = try target.context.fetch(FetchDescriptor<AuditLog>())
        let restoredPlan = try #require(
            restoredPlans.first { $0.uuid == installmentPlan.uuid }
        )
        let restoredPeriod = try #require(
            restoredPeriods.first { $0.uuid == installmentPeriod.uuid }
        )
        let restoredRule = try #require(
            restoredRules.first { $0.uuid == recurringRule.uuid }
        )
        let restoredLink = try #require(
            restoredLinks.first { $0.uuid == transactionLink.uuid }
        )
        let restoredBudget = try #require(
            restoredBudgets.first { $0.uuid == budget.uuid }
        )
        let restoredSnapshot = try #require(
            restoredSnapshots.first { $0.uuid == balanceSnapshot.uuid }
        )
        let restoredAudit = try #require(
            restoredAudits.first { $0.uuid == auditLog.uuid }
        )

        #expect(restoredCreditAccount.kindRawValue == AccountKind.credit.rawValue)
        #expect(restoredCreditAccount.creditPoolID == creditPool.uuid)
        #expect(restoredExpenseChild.parentID == expenseParent.uuid)
        #expect(restoredExpenseChild.ledgerID == ledger.uuid)

        #expect(restoredImported.account?.uuid == usdAccount.uuid)
        #expect(restoredImported.category?.uuid == expenseChild.uuid)
        #expect(restoredImported.tags?.map(\.uuid) == [tag.uuid])
        #expect(restoredImported.fxRateToBase == transactionRate)
        #expect(restoredImported.attachmentFileNames == [attachmentFileName])
        #expect(
            restoredImported.reimbursementStatusRawValue
                == ReimbursementStatus.waiting.rawValue
        )
        #expect(
            restoredRecurring.settlementKindRawValue
                == TransactionLinkKind.reimbursement.rawValue
        )
        #expect(restoredInstallment.targetAccount?.uuid == creditAccount.uuid)
        #expect(
            [
                restoredImported.sourceKindRawValue,
                restoredRecurring.sourceKindRawValue,
                restoredInstallment.sourceKindRawValue,
            ] == [
                TransactionSourceKind.csvImport.rawValue,
                TransactionSourceKind.recurring.rawValue,
                TransactionSourceKind.installment.rawValue,
            ]
        )
        #expect(restoredImported.sourceID == importBatch.uuid)
        #expect(restoredRecurring.sourceID == recurringRule.uuid)
        #expect(restoredInstallment.sourceID == installmentPlan.uuid)

        #expect(restoredRule.templateLedgerID == ledger.uuid)
        #expect(restoredRule.templateAccountID == usdAccount.uuid)
        #expect(restoredRule.templateCategoryID == incomeCategory.uuid)
        #expect(restoredRule.templateTagIDs == [tag.uuid])
        #expect(restoredRule.frequencyRawValue == RecurrenceFrequency.monthly.rawValue)
        #expect(restoredRule.templateKindRawValue == TransactionKind.income.rawValue)

        #expect(restoredPeriod.planID == installmentPlan.uuid)
        #expect(restoredPeriod.settledTransactionID == installmentTransaction.uuid)
        #expect(restoredPeriod.statusRawValue == InstallmentPeriodStatus.settled.rawValue)
        #expect(restoredPlan.totalChargeMinorUnits == 1_200)
        #expect(restoredPlan.closedAt == closedDate)
        #expect(
            [
                restoredPlan.kindRawValue,
                restoredPlan.amortizationKindRawValue,
                restoredPlan.chargeCollectionKindRawValue,
                restoredPlan.principalRoundingKindRawValue,
                restoredPlan.principalRemainderKindRawValue,
                restoredPlan.chargeRoundingKindRawValue,
                restoredPlan.chargeRemainderKindRawValue,
                restoredPlan.statusRawValue,
            ] == [
                InstallmentPlanKind.statement.rawValue,
                AmortizationKind.flatFee.rawValue,
                ChargeCollectionKind.upfrontFirstPeriod.rawValue,
                InstallmentRoundingKind.nearestMajorUnit.rawValue,
                InstallmentRemainderKind.firstPeriod.rawValue,
                InstallmentRoundingKind.nearestMinorUnit.rawValue,
                InstallmentRemainderKind.firstPeriod.rawValue,
                InstallmentPlanStatus.completed.rawValue,
            ]
        )

        #expect(restoredLink.originalTransactionID == importedTransaction.uuid)
        #expect(restoredLink.settlementTransactionID == recurringTransaction.uuid)
        #expect(restoredLink.kindRawValue == TransactionLinkKind.reimbursement.rawValue)
        #expect(restoredSnapshot.accountID == usdAccount.uuid)
        #expect(restoredSnapshot.fxRateToBase == snapshotRate)
        #expect(restoredBudget.isSoftDeleted)
        #expect(restoredAudit.isSoftDeleted)
    }
}
