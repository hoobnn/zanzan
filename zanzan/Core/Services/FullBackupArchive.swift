import Foundation
import SwiftData

nonisolated enum ZanzanBackupPayloadError: LocalizedError, Equatable {
    case duplicateUUID(entity: String)
    case brokenReference(entity: String, field: String)
    case invalidHierarchy(entity: String)

    var errorDescription: String? {
        switch self {
        case let .duplicateUUID(entity):
            ZanzanLocalization.string("备份中 \(entity) 存在重复 UUID")
        case let .brokenReference(entity, field):
            ZanzanLocalization.string("备份中 \(entity).\(field) 引用无效")
        case let .invalidHierarchy(entity):
            ZanzanLocalization.string("备份中 \(entity) 层级关系无效")
        }
    }
}

struct ZanzanBackupPayload: Codable, Equatable {
    var ledgers: [LedgerRecord]
    var accounts: [AccountRecord]
    var categories: [CategoryRecord]
    var transactions: [TransactionRecord]
    var tags: [TagRecord]
    var transactionLinks: [TransactionLinkRecord]
    var budgets: [BudgetRecord]
    var creditPools: [CreditPoolRecord]
    var installmentPlans: [InstallmentPlanRecord]
    var installmentPeriods: [InstallmentPeriodRecord]
    var recurringRules: [RecurringRuleRecord]
    var importBatches: [ImportBatchRecord]
    var balanceSnapshots: [BalanceSnapshotRecord]
    var auditLogs: [AuditLogRecord]

    var referencedAttachmentFileNames: [String] {
        transactions.flatMap(\.attachmentFileNames)
    }

    var recordCount: Int {
        ledgers.count
            + accounts.count
            + categories.count
            + transactions.count
            + tags.count
            + transactionLinks.count
            + budgets.count
            + creditPools.count
            + installmentPlans.count
            + installmentPeriods.count
            + recurringRules.count
            + importBatches.count
            + balanceSnapshots.count
            + auditLogs.count
    }

    init(context: ModelContext) throws {
        func sortedByUUID<Record>(
            _ records: [Record],
            uuid: (Record) -> UUID
        ) -> [Record] {
            records.sorted { uuid($0).uuidString < uuid($1).uuidString }
        }

        ledgers = sortedByUUID(
            try context.fetch(FetchDescriptor<Ledger>()).map(LedgerRecord.init),
            uuid: \.uuid
        )
        accounts = sortedByUUID(
            try context.fetch(FetchDescriptor<Account>()).map(AccountRecord.init),
            uuid: \.uuid
        )
        categories = sortedByUUID(
            try context.fetch(FetchDescriptor<Category>()).map(CategoryRecord.init),
            uuid: \.uuid
        )
        transactions = sortedByUUID(
            try context.fetch(FetchDescriptor<Transaction>()).map(TransactionRecord.init),
            uuid: \.uuid
        )
        tags = sortedByUUID(
            try context.fetch(FetchDescriptor<Tag>()).map(TagRecord.init),
            uuid: \.uuid
        )
        transactionLinks = sortedByUUID(
            try context.fetch(FetchDescriptor<TransactionLink>()).map(TransactionLinkRecord.init),
            uuid: \.uuid
        )
        budgets = sortedByUUID(
            try context.fetch(FetchDescriptor<Budget>()).map(BudgetRecord.init),
            uuid: \.uuid
        )
        creditPools = sortedByUUID(
            try context.fetch(FetchDescriptor<CreditPool>()).map(CreditPoolRecord.init),
            uuid: \.uuid
        )
        installmentPlans = sortedByUUID(
            try context.fetch(FetchDescriptor<InstallmentPlan>()).map(InstallmentPlanRecord.init),
            uuid: \.uuid
        )
        installmentPeriods = sortedByUUID(
            try context.fetch(FetchDescriptor<InstallmentPeriod>()).map(InstallmentPeriodRecord.init),
            uuid: \.uuid
        )
        recurringRules = sortedByUUID(
            try context.fetch(FetchDescriptor<RecurringRule>()).map(RecurringRuleRecord.init),
            uuid: \.uuid
        )
        importBatches = sortedByUUID(
            try context.fetch(FetchDescriptor<ImportBatch>()).map(ImportBatchRecord.init),
            uuid: \.uuid
        )
        balanceSnapshots = sortedByUUID(
            try context.fetch(FetchDescriptor<BalanceSnapshot>()).map(BalanceSnapshotRecord.init),
            uuid: \.uuid
        )
        auditLogs = sortedByUUID(
            try context.fetch(FetchDescriptor<AuditLog>()).map(AuditLogRecord.init),
            uuid: \.uuid
        )
    }

    func validateReferences() throws {
        func unique(_ ids: [UUID], entity: String) throws -> Set<UUID> {
            let values = Set(ids)
            guard values.count == ids.count else {
                throw ZanzanBackupPayloadError.duplicateUUID(entity: entity)
            }
            return values
        }

        func require(
            _ id: UUID?,
            in ids: Set<UUID>,
            entity: String,
            field: String
        ) throws {
            guard let id else { return }
            guard ids.contains(id) else {
                throw ZanzanBackupPayloadError.brokenReference(entity: entity, field: field)
            }
        }

        func requirePresent(
            _ id: UUID?,
            in ids: Set<UUID>,
            entity: String,
            field: String
        ) throws -> UUID {
            guard let id, ids.contains(id) else {
                throw ZanzanBackupPayloadError.brokenReference(entity: entity, field: field)
            }
            return id
        }

        let ledgerIDs = try unique(ledgers.map(\.uuid), entity: "Ledger")
        let accountIDs = try unique(accounts.map(\.uuid), entity: "Account")
        let categoryIDs = try unique(categories.map(\.uuid), entity: "Category")
        let transactionIDs = try unique(transactions.map(\.uuid), entity: "Transaction")
        let tagIDs = try unique(tags.map(\.uuid), entity: "Tag")
        _ = try unique(transactionLinks.map(\.uuid), entity: "TransactionLink")
        _ = try unique(budgets.map(\.uuid), entity: "Budget")
        let creditPoolIDs = try unique(creditPools.map(\.uuid), entity: "CreditPool")
        let installmentPlanIDs = try unique(installmentPlans.map(\.uuid), entity: "InstallmentPlan")
        _ = try unique(installmentPeriods.map(\.uuid), entity: "InstallmentPeriod")
        let recurringRuleIDs = try unique(recurringRules.map(\.uuid), entity: "RecurringRule")
        let importBatchIDs = try unique(importBatches.map(\.uuid), entity: "ImportBatch")
        _ = try unique(balanceSnapshots.map(\.uuid), entity: "BalanceSnapshot")
        _ = try unique(auditLogs.map(\.uuid), entity: "AuditLog")

        for account in accounts {
            try require(
                account.creditPoolID,
                in: creditPoolIDs,
                entity: "Account",
                field: "creditPoolID"
            )
        }
        for category in categories {
            try require(category.parentID, in: categoryIDs, entity: "Category", field: "parentID")
            try require(category.ledgerID, in: ledgerIDs, entity: "Category", field: "ledgerID")
        }
        let parentByCategoryID = Dictionary(
            uniqueKeysWithValues: categories.map { ($0.uuid, $0.parentID) }
        )
        let categoriesByID = Dictionary(
            uniqueKeysWithValues: categories.map { ($0.uuid, $0) }
        )
        for category in categories {
            if let parentID = category.parentID,
               let parent = categoriesByID[parentID] {
                guard parent.kindRawValue == category.kindRawValue,
                      parent.ledgerID == category.ledgerID,
                      category.isSoftDeleted || !parent.isSoftDeleted else {
                    throw ZanzanBackupPayloadError.invalidHierarchy(entity: "Category")
                }
            }
            var visited: Set<UUID> = [category.uuid]
            var ancestorID = category.parentID
            var depth = 0
            while let currentID = ancestorID {
                guard visited.insert(currentID).inserted else {
                    throw ZanzanBackupPayloadError.invalidHierarchy(entity: "Category")
                }
                depth += 1
                guard depth <= 1 else {
                    throw ZanzanBackupPayloadError.invalidHierarchy(entity: "Category")
                }
                ancestorID = parentByCategoryID[currentID] ?? nil
            }
        }
        for transaction in transactions {
            try require(transaction.ledgerID, in: ledgerIDs, entity: "Transaction", field: "ledgerID")
            try require(transaction.accountID, in: accountIDs, entity: "Transaction", field: "accountID")
            try require(
                transaction.targetAccountID,
                in: accountIDs,
                entity: "Transaction",
                field: "targetAccountID"
            )
            try require(
                transaction.categoryID,
                in: categoryIDs,
                entity: "Transaction",
                field: "categoryID"
            )
            for tagID in transaction.tagIDs ?? [] {
                try require(tagID, in: tagIDs, entity: "Transaction", field: "tagIDs")
            }
            if let kind = TransactionKind(rawValue: transaction.kindRawValue) {
                _ = try requirePresent(
                    transaction.ledgerID,
                    in: ledgerIDs,
                    entity: "Transaction",
                    field: "ledgerID"
                )
                let accountID = try requirePresent(
                    transaction.accountID,
                    in: accountIDs,
                    entity: "Transaction",
                    field: "accountID"
                )
                switch kind {
                case .expense, .income:
                    _ = try requirePresent(
                        transaction.categoryID,
                        in: categoryIDs,
                        entity: "Transaction",
                        field: "categoryID"
                    )
                    guard transaction.targetAccountID == nil else {
                        throw ZanzanBackupPayloadError.brokenReference(
                            entity: "Transaction",
                            field: "targetAccountID"
                        )
                    }
                case .transfer:
                    let targetAccountID = try requirePresent(
                        transaction.targetAccountID,
                        in: accountIDs,
                        entity: "Transaction",
                        field: "targetAccountID"
                    )
                    guard transaction.categoryID == nil,
                          targetAccountID != accountID else {
                        throw ZanzanBackupPayloadError.brokenReference(
                            entity: "Transaction",
                            field: "categoryID/targetAccountID"
                        )
                    }
                }
            }
            switch transaction.sourceKindRawValue {
            case TransactionSourceKind.csvImport.rawValue:
                _ = try requirePresent(
                    transaction.sourceID,
                    in: importBatchIDs,
                    entity: "Transaction",
                    field: "sourceID"
                )
            case TransactionSourceKind.recurring.rawValue:
                _ = try requirePresent(
                    transaction.sourceID,
                    in: recurringRuleIDs,
                    entity: "Transaction",
                    field: "sourceID"
                )
            case TransactionSourceKind.installment.rawValue:
                _ = try requirePresent(
                    transaction.sourceID,
                    in: installmentPlanIDs,
                    entity: "Transaction",
                    field: "sourceID"
                )
            default:
                break // 未知/无来源表类型的 opaque ID 必须原样保留
            }
        }
        for tag in tags {
            try require(tag.ledgerID, in: ledgerIDs, entity: "Tag", field: "ledgerID")
        }
        for link in transactionLinks {
            try require(
                link.originalTransactionID,
                in: transactionIDs,
                entity: "TransactionLink",
                field: "originalTransactionID"
            )
            try require(
                link.settlementTransactionID,
                in: transactionIDs,
                entity: "TransactionLink",
                field: "settlementTransactionID"
            )
        }
        for budget in budgets {
            try require(budget.ledgerID, in: ledgerIDs, entity: "Budget", field: "ledgerID")
            try require(budget.categoryID, in: categoryIDs, entity: "Budget", field: "categoryID")
        }
        for plan in installmentPlans {
            try require(plan.accountID, in: accountIDs, entity: "InstallmentPlan", field: "accountID")
            try require(plan.ledgerID, in: ledgerIDs, entity: "InstallmentPlan", field: "ledgerID")
        }
        for period in installmentPeriods {
            try require(
                period.planID,
                in: installmentPlanIDs,
                entity: "InstallmentPeriod",
                field: "planID"
            )
            try require(
                period.settledTransactionID,
                in: transactionIDs,
                entity: "InstallmentPeriod",
                field: "settledTransactionID"
            )
        }
        for rule in recurringRules {
            try require(
                rule.templateLedgerID,
                in: ledgerIDs,
                entity: "RecurringRule",
                field: "templateLedgerID"
            )
            try require(
                rule.templateAccountID,
                in: accountIDs,
                entity: "RecurringRule",
                field: "templateAccountID"
            )
            try require(
                rule.templateTargetAccountID,
                in: accountIDs,
                entity: "RecurringRule",
                field: "templateTargetAccountID"
            )
            try require(
                rule.templateCategoryID,
                in: categoryIDs,
                entity: "RecurringRule",
                field: "templateCategoryID"
            )
            for tagID in rule.templateTagIDs {
                try require(tagID, in: tagIDs, entity: "RecurringRule", field: "templateTagIDs")
            }
            if let kind = TransactionKind(rawValue: rule.templateKindRawValue) {
                _ = try requirePresent(
                    rule.templateLedgerID,
                    in: ledgerIDs,
                    entity: "RecurringRule",
                    field: "templateLedgerID"
                )
                let accountID = try requirePresent(
                    rule.templateAccountID,
                    in: accountIDs,
                    entity: "RecurringRule",
                    field: "templateAccountID"
                )
                switch kind {
                case .expense, .income:
                    _ = try requirePresent(
                        rule.templateCategoryID,
                        in: categoryIDs,
                        entity: "RecurringRule",
                        field: "templateCategoryID"
                    )
                    guard rule.templateTargetAccountID == nil else {
                        throw ZanzanBackupPayloadError.brokenReference(
                            entity: "RecurringRule",
                            field: "templateTargetAccountID"
                        )
                    }
                case .transfer:
                    let targetAccountID = try requirePresent(
                        rule.templateTargetAccountID,
                        in: accountIDs,
                        entity: "RecurringRule",
                        field: "templateTargetAccountID"
                    )
                    guard rule.templateCategoryID == nil,
                          targetAccountID != accountID else {
                        throw ZanzanBackupPayloadError.brokenReference(
                            entity: "RecurringRule",
                            field: "templateCategoryID/templateTargetAccountID"
                        )
                    }
                }
            }
        }
        for snapshot in balanceSnapshots {
            try require(
                snapshot.accountID,
                in: accountIDs,
                entity: "BalanceSnapshot",
                field: "accountID"
            )
        }
    }

    /// 仅暂存模型；调用方负责最终保存或回滚。
    func insertAll(into context: ModelContext) throws {
        try validateReferences()

        let ledgerModels = ledgers.map { ($0.uuid, $0.makeModel()) }
        let creditPoolModels = creditPools.map { ($0.uuid, $0.makeModel()) }
        let accountModels = accounts.map { ($0.uuid, $0.makeModel()) }
        let categoryModels = categories.map { ($0.uuid, $0.makeModel()) }
        let tagModels = tags.map { ($0.uuid, $0.makeModel()) }
        let installmentPlanModels = installmentPlans.map { ($0.uuid, $0.makeModel()) }
        let recurringRuleModels = recurringRules.map { ($0.uuid, $0.makeModel()) }
        let importBatchModels = importBatches.map { ($0.uuid, $0.makeModel()) }

        for model in ledgerModels.map(\.1) { context.insert(model) }
        for model in creditPoolModels.map(\.1) { context.insert(model) }
        for model in accountModels.map(\.1) { context.insert(model) }
        for model in categoryModels.map(\.1) { context.insert(model) }
        for model in tagModels.map(\.1) { context.insert(model) }
        for model in installmentPlanModels.map(\.1) { context.insert(model) }
        for model in recurringRuleModels.map(\.1) { context.insert(model) }
        for model in importBatchModels.map(\.1) { context.insert(model) }

        let accountsByID = Dictionary(uniqueKeysWithValues: accountModels)
        let categoriesByID = Dictionary(uniqueKeysWithValues: categoryModels)
        let tagsByID = Dictionary(uniqueKeysWithValues: tagModels)
        for record in transactions {
            let model = record.makeModel()
            if let accountID = record.accountID {
                guard let account = accountsByID[accountID] else {
                    throw ZanzanBackupPayloadError.brokenReference(
                        entity: "Transaction",
                        field: "accountID"
                    )
                }
                model.account = account
            }
            if let targetAccountID = record.targetAccountID {
                guard let account = accountsByID[targetAccountID] else {
                    throw ZanzanBackupPayloadError.brokenReference(
                        entity: "Transaction",
                        field: "targetAccountID"
                    )
                }
                model.targetAccount = account
            }
            if let categoryID = record.categoryID {
                guard let category = categoriesByID[categoryID] else {
                    throw ZanzanBackupPayloadError.brokenReference(
                        entity: "Transaction",
                        field: "categoryID"
                    )
                }
                model.category = category
            }
            if let tagIDs = record.tagIDs {
                model.tags = try tagIDs.map { tagID in
                    guard let tag = tagsByID[tagID] else {
                        throw ZanzanBackupPayloadError.brokenReference(
                            entity: "Transaction",
                            field: "tagIDs"
                        )
                    }
                    return tag
                }
            }
            context.insert(model)
        }

        for record in transactionLinks { context.insert(record.makeModel()) }
        for record in budgets { context.insert(record.makeModel()) }
        for record in installmentPeriods { context.insert(record.makeModel()) }
        for record in balanceSnapshots { context.insert(record.makeModel()) }
        for record in auditLogs { context.insert(record.makeModel()) }
    }
}

extension ZanzanBackupPayload {
    struct LedgerRecord: Codable, Equatable {
        var uuid: UUID
        var name: String
        var isDefault: Bool
        var iconKindRawValue: String
        var iconPrimary: String
        var iconSecondary: String
        var iconIndex: Int
        var colorID: String
        var isArchived: Bool
        var sortOrder: Int
        var isSoftDeleted: Bool
        var createdAt: Date
        var updatedAt: Date

        init(_ model: Ledger) {
            uuid = model.uuid
            name = model.name
            isDefault = model.isDefault
            iconKindRawValue = model.iconKindRawValue
            iconPrimary = model.iconPrimary
            iconSecondary = model.iconSecondary
            iconIndex = model.iconIndex
            colorID = model.colorID
            isArchived = model.isArchived
            sortOrder = model.sortOrder
            isSoftDeleted = model.isSoftDeleted
            createdAt = model.createdAt
            updatedAt = model.updatedAt
        }

        func makeModel() -> Ledger {
            let model = Ledger(name: name)
            model.uuid = uuid
            model.isDefault = isDefault
            model.iconKindRawValue = iconKindRawValue
            model.iconPrimary = iconPrimary
            model.iconSecondary = iconSecondary
            model.iconIndex = iconIndex
            model.colorID = colorID
            model.isArchived = isArchived
            model.sortOrder = sortOrder
            model.isSoftDeleted = isSoftDeleted
            model.createdAt = createdAt
            model.updatedAt = updatedAt
            return model
        }
    }

    struct AccountRecord: Codable, Equatable {
        var uuid: UUID
        var name: String
        var subtitle: String
        var kindRawValue: String
        var iconKindRawValue: String
        var iconPrimary: String
        var iconSecondary: String
        var iconIndex: Int
        var currencyCode: String
        var initialBalanceMinorUnits: Int
        var creditLimitMinorUnits: Int?
        var creditPoolID: UUID?
        var statementDay: Int?
        var paymentDueDay: Int?
        var note: String
        var isIncludedInNetWorth: Bool
        var isSelectableForRecord: Bool
        var isArchived: Bool
        var sortOrder: Int
        var isSoftDeleted: Bool
        var createdAt: Date
        var updatedAt: Date

        init(_ model: Account) {
            uuid = model.uuid
            name = model.name
            subtitle = model.subtitle
            kindRawValue = model.kindRawValue
            iconKindRawValue = model.iconKindRawValue
            iconPrimary = model.iconPrimary
            iconSecondary = model.iconSecondary
            iconIndex = model.iconIndex
            currencyCode = model.currencyCode
            initialBalanceMinorUnits = model.initialBalanceMinorUnits
            creditLimitMinorUnits = model.creditLimitMinorUnits
            creditPoolID = model.creditPoolID
            statementDay = model.statementDay
            paymentDueDay = model.paymentDueDay
            note = model.note
            isIncludedInNetWorth = model.isIncludedInNetWorth
            isSelectableForRecord = model.isSelectableForRecord
            isArchived = model.isArchived
            sortOrder = model.sortOrder
            isSoftDeleted = model.isSoftDeleted
            createdAt = model.createdAt
            updatedAt = model.updatedAt
        }

        func makeModel() -> Account {
            let model = Account(name: name, kind: .fund)
            model.uuid = uuid
            model.subtitle = subtitle
            model.kindRawValue = kindRawValue
            model.iconKindRawValue = iconKindRawValue
            model.iconPrimary = iconPrimary
            model.iconSecondary = iconSecondary
            model.iconIndex = iconIndex
            model.currencyCode = currencyCode
            model.initialBalanceMinorUnits = initialBalanceMinorUnits
            model.creditLimitMinorUnits = creditLimitMinorUnits
            model.creditPoolID = creditPoolID
            model.statementDay = statementDay
            model.paymentDueDay = paymentDueDay
            model.note = note
            model.isIncludedInNetWorth = isIncludedInNetWorth
            model.isSelectableForRecord = isSelectableForRecord
            model.isArchived = isArchived
            model.sortOrder = sortOrder
            model.isSoftDeleted = isSoftDeleted
            model.createdAt = createdAt
            model.updatedAt = updatedAt
            return model
        }
    }

    struct CategoryRecord: Codable, Equatable {
        var uuid: UUID
        var name: String
        var kindRawValue: String
        var iconKindRawValue: String
        var iconPrimary: String
        var iconSecondary: String
        var iconIndex: Int
        var sortOrder: Int
        var parentID: UUID?
        var ledgerID: UUID?
        var isBuiltIn: Bool
        var isArchived: Bool
        var isSoftDeleted: Bool
        var createdAt: Date
        var updatedAt: Date

        init(_ model: Category) {
            uuid = model.uuid
            name = model.name
            kindRawValue = model.kindRawValue
            iconKindRawValue = model.iconKindRawValue
            iconPrimary = model.iconPrimary
            iconSecondary = model.iconSecondary
            iconIndex = model.iconIndex
            sortOrder = model.sortOrder
            parentID = model.parentID
            ledgerID = model.ledgerID
            isBuiltIn = model.isBuiltIn
            isArchived = model.isArchived
            isSoftDeleted = model.isSoftDeleted
            createdAt = model.createdAt
            updatedAt = model.updatedAt
        }

        func makeModel() -> Category {
            let model = Category(name: name, kind: .expense, sortOrder: sortOrder)
            model.uuid = uuid
            model.kindRawValue = kindRawValue
            model.iconKindRawValue = iconKindRawValue
            model.iconPrimary = iconPrimary
            model.iconSecondary = iconSecondary
            model.iconIndex = iconIndex
            model.parentID = parentID
            model.ledgerID = ledgerID
            model.isBuiltIn = isBuiltIn
            model.isArchived = isArchived
            model.isSoftDeleted = isSoftDeleted
            model.createdAt = createdAt
            model.updatedAt = updatedAt
            return model
        }
    }

    struct TransactionRecord: Codable, Equatable {
        var uuid: UUID
        var kindRawValue: String
        var amountMinorUnits: Int
        var occurredAt: Date
        var note: String
        var ledgerID: UUID?
        var accountID: UUID?
        var targetAccountID: UUID?
        var categoryID: UUID?
        var tagIDs: [UUID]?
        var attachmentFileNames: [String]
        var locationName: String
        var locationLatitude: Double?
        var locationLongitude: Double?
        var isExcludedFromBudget: Bool
        var isExcludedFromStats: Bool
        var currencyCode: String
        var targetAmountMinorUnits: Int?
        var fxRateToBase: Decimal?
        var feeMinorUnits: Int
        var sourceKindRawValue: String
        var sourceID: UUID?
        var reimbursementStatusRawValue: String
        var settlementKindRawValue: String
        var isSoftDeleted: Bool
        var createdAt: Date
        var updatedAt: Date

        init(_ model: Transaction) {
            uuid = model.uuid
            kindRawValue = model.kindRawValue
            amountMinorUnits = model.amountMinorUnits
            occurredAt = model.occurredAt
            note = model.note
            ledgerID = model.ledgerID
            accountID = model.account?.uuid
            targetAccountID = model.targetAccount?.uuid
            categoryID = model.category?.uuid
            tagIDs = model.tags?.map(\.uuid).sorted { $0.uuidString < $1.uuidString }
            attachmentFileNames = model.attachmentFileNames
            locationName = model.locationName
            locationLatitude = model.locationLatitude
            locationLongitude = model.locationLongitude
            isExcludedFromBudget = model.isExcludedFromBudget
            isExcludedFromStats = model.isExcludedFromStats
            currencyCode = model.currencyCode
            targetAmountMinorUnits = model.targetAmountMinorUnits
            fxRateToBase = model.fxRateToBase
            feeMinorUnits = model.feeMinorUnits
            sourceKindRawValue = model.sourceKindRawValue
            sourceID = model.sourceID
            reimbursementStatusRawValue = model.reimbursementStatusRawValue
            settlementKindRawValue = model.settlementKindRawValue
            isSoftDeleted = model.isSoftDeleted
            createdAt = model.createdAt
            updatedAt = model.updatedAt
        }

        func makeModel() -> Transaction {
            let model = Transaction(
                kind: .expense,
                amountMinorUnits: amountMinorUnits,
                occurredAt: occurredAt,
                ledgerID: ledgerID ?? UUID()
            )
            model.uuid = uuid
            model.kindRawValue = kindRawValue
            model.note = note
            model.ledgerID = ledgerID
            model.attachmentFileNames = attachmentFileNames
            model.locationName = locationName
            model.locationLatitude = locationLatitude
            model.locationLongitude = locationLongitude
            model.isExcludedFromBudget = isExcludedFromBudget
            model.isExcludedFromStats = isExcludedFromStats
            model.currencyCode = currencyCode
            model.targetAmountMinorUnits = targetAmountMinorUnits
            model.fxRateToBase = fxRateToBase
            model.feeMinorUnits = feeMinorUnits
            model.sourceKindRawValue = sourceKindRawValue
            model.sourceID = sourceID
            model.reimbursementStatusRawValue = reimbursementStatusRawValue
            model.settlementKindRawValue = settlementKindRawValue
            model.isSoftDeleted = isSoftDeleted
            model.createdAt = createdAt
            model.updatedAt = updatedAt
            return model
        }
    }

    struct TagRecord: Codable, Equatable {
        var uuid: UUID
        var name: String
        var colorID: String
        var sortOrder: Int
        var ledgerID: UUID?
        var isArchived: Bool
        var isSoftDeleted: Bool
        var createdAt: Date
        var updatedAt: Date

        init(_ model: Tag) {
            uuid = model.uuid
            name = model.name
            colorID = model.colorID
            sortOrder = model.sortOrder
            ledgerID = model.ledgerID
            isArchived = model.isArchived
            isSoftDeleted = model.isSoftDeleted
            createdAt = model.createdAt
            updatedAt = model.updatedAt
        }

        func makeModel() -> Tag {
            let model = Tag(name: name)
            model.uuid = uuid
            model.colorID = colorID
            model.sortOrder = sortOrder
            model.ledgerID = ledgerID
            model.isArchived = isArchived
            model.isSoftDeleted = isSoftDeleted
            model.createdAt = createdAt
            model.updatedAt = updatedAt
            return model
        }
    }

    struct TransactionLinkRecord: Codable, Equatable {
        var uuid: UUID
        var originalTransactionID: UUID
        var settlementTransactionID: UUID
        var kindRawValue: String
        var amountMinorUnits: Int
        var isSoftDeleted: Bool
        var createdAt: Date
        var updatedAt: Date

        init(_ model: TransactionLink) {
            uuid = model.uuid
            originalTransactionID = model.originalTransactionID
            settlementTransactionID = model.settlementTransactionID
            kindRawValue = model.kindRawValue
            amountMinorUnits = model.amountMinorUnits
            isSoftDeleted = model.isSoftDeleted
            createdAt = model.createdAt
            updatedAt = model.updatedAt
        }

        func makeModel() -> TransactionLink {
            let model = TransactionLink(
                originalTransactionID: originalTransactionID,
                settlementTransactionID: settlementTransactionID,
                kind: .reimbursement,
                amountMinorUnits: amountMinorUnits
            )
            model.uuid = uuid
            model.kindRawValue = kindRawValue
            model.isSoftDeleted = isSoftDeleted
            model.createdAt = createdAt
            model.updatedAt = updatedAt
            return model
        }
    }

    struct BudgetRecord: Codable, Equatable {
        var uuid: UUID
        var ledgerID: UUID
        var categoryID: UUID?
        var periodYear: Int?
        var periodMonth: Int?
        var amountMinorUnits: Int
        var isSoftDeleted: Bool
        var createdAt: Date
        var updatedAt: Date

        init(_ model: Budget) {
            uuid = model.uuid
            ledgerID = model.ledgerID
            categoryID = model.categoryID
            periodYear = model.periodYear
            periodMonth = model.periodMonth
            amountMinorUnits = model.amountMinorUnits
            isSoftDeleted = model.isSoftDeleted
            createdAt = model.createdAt
            updatedAt = model.updatedAt
        }

        func makeModel() -> Budget {
            let model = Budget(ledgerID: ledgerID, amountMinorUnits: amountMinorUnits)
            model.uuid = uuid
            model.categoryID = categoryID
            model.periodYear = periodYear
            model.periodMonth = periodMonth
            model.isSoftDeleted = isSoftDeleted
            model.createdAt = createdAt
            model.updatedAt = updatedAt
            return model
        }
    }

    struct CreditPoolRecord: Codable, Equatable {
        var uuid: UUID
        var name: String
        var totalLimitMinorUnits: Int
        var currencyCode: String
        var iconKindRawValue: String
        var iconPrimary: String
        var iconSecondary: String
        var iconIndex: Int
        var note: String
        var sortOrder: Int
        var isSoftDeleted: Bool
        var createdAt: Date
        var updatedAt: Date

        init(_ model: CreditPool) {
            uuid = model.uuid
            name = model.name
            totalLimitMinorUnits = model.totalLimitMinorUnits
            currencyCode = model.currencyCode
            iconKindRawValue = model.iconKindRawValue
            iconPrimary = model.iconPrimary
            iconSecondary = model.iconSecondary
            iconIndex = model.iconIndex
            note = model.note
            sortOrder = model.sortOrder
            isSoftDeleted = model.isSoftDeleted
            createdAt = model.createdAt
            updatedAt = model.updatedAt
        }

        func makeModel() -> CreditPool {
            let model = CreditPool(name: name, totalLimitMinorUnits: totalLimitMinorUnits)
            model.uuid = uuid
            model.currencyCode = currencyCode
            model.iconKindRawValue = iconKindRawValue
            model.iconPrimary = iconPrimary
            model.iconSecondary = iconSecondary
            model.iconIndex = iconIndex
            model.note = note
            model.sortOrder = sortOrder
            model.isSoftDeleted = isSoftDeleted
            model.createdAt = createdAt
            model.updatedAt = updatedAt
            return model
        }
    }

    struct InstallmentPlanRecord: Codable, Equatable {
        var uuid: UUID
        var name: String
        var kindRawValue: String
        var accountID: UUID
        var ledgerID: UUID
        var principalMinorUnits: Int
        var totalPeriods: Int
        var annualRateBps: Int?
        var amortizationKindRawValue: String
        var totalChargeMinorUnits: Int?
        var chargeCollectionKindRawValue: String
        var principalRoundingKindRawValue: String
        var principalRemainderKindRawValue: String
        var chargeRoundingKindRawValue: String
        var chargeRemainderKindRawValue: String
        var firstDueAt: Date
        var isAutoSettle: Bool
        var statusRawValue: String
        var closedAt: Date?
        var note: String
        var isSoftDeleted: Bool
        var createdAt: Date
        var updatedAt: Date

        init(_ model: InstallmentPlan) {
            uuid = model.uuid
            name = model.name
            kindRawValue = model.kindRawValue
            accountID = model.accountID
            ledgerID = model.ledgerID
            principalMinorUnits = model.principalMinorUnits
            totalPeriods = model.totalPeriods
            annualRateBps = model.annualRateBps
            amortizationKindRawValue = model.amortizationKindRawValue
            totalChargeMinorUnits = model.totalChargeMinorUnits
            chargeCollectionKindRawValue = model.chargeCollectionKindRawValue
            principalRoundingKindRawValue = model.principalRoundingKindRawValue
            principalRemainderKindRawValue = model.principalRemainderKindRawValue
            chargeRoundingKindRawValue = model.chargeRoundingKindRawValue
            chargeRemainderKindRawValue = model.chargeRemainderKindRawValue
            firstDueAt = model.firstDueAt
            isAutoSettle = model.isAutoSettle
            statusRawValue = model.statusRawValue
            closedAt = model.closedAt
            note = model.note
            isSoftDeleted = model.isSoftDeleted
            createdAt = model.createdAt
            updatedAt = model.updatedAt
        }

        func makeModel() -> InstallmentPlan {
            let model = InstallmentPlan(
                name: name,
                kind: .purchase,
                accountID: accountID,
                ledgerID: ledgerID,
                principalMinorUnits: principalMinorUnits,
                totalPeriods: totalPeriods,
                amortizationKind: .annuity,
                firstDueAt: firstDueAt
            )
            model.uuid = uuid
            model.kindRawValue = kindRawValue
            model.annualRateBps = annualRateBps
            model.amortizationKindRawValue = amortizationKindRawValue
            model.totalChargeMinorUnits = totalChargeMinorUnits
            model.chargeCollectionKindRawValue = chargeCollectionKindRawValue
            model.principalRoundingKindRawValue = principalRoundingKindRawValue
            model.principalRemainderKindRawValue = principalRemainderKindRawValue
            model.chargeRoundingKindRawValue = chargeRoundingKindRawValue
            model.chargeRemainderKindRawValue = chargeRemainderKindRawValue
            model.isAutoSettle = isAutoSettle
            model.statusRawValue = statusRawValue
            model.closedAt = closedAt
            model.note = note
            model.isSoftDeleted = isSoftDeleted
            model.createdAt = createdAt
            model.updatedAt = updatedAt
            return model
        }
    }

    struct InstallmentPeriodRecord: Codable, Equatable {
        var uuid: UUID
        var planID: UUID
        var periodIndex: Int
        var dueAt: Date
        var principalMinorUnits: Int
        var interestMinorUnits: Int
        var statusRawValue: String
        var settledAt: Date?
        var settledTransactionID: UUID?
        var isSoftDeleted: Bool
        var createdAt: Date
        var updatedAt: Date

        init(_ model: InstallmentPeriod) {
            uuid = model.uuid
            planID = model.planID
            periodIndex = model.periodIndex
            dueAt = model.dueAt
            principalMinorUnits = model.principalMinorUnits
            interestMinorUnits = model.interestMinorUnits
            statusRawValue = model.statusRawValue
            settledAt = model.settledAt
            settledTransactionID = model.settledTransactionID
            isSoftDeleted = model.isSoftDeleted
            createdAt = model.createdAt
            updatedAt = model.updatedAt
        }

        func makeModel() -> InstallmentPeriod {
            let model = InstallmentPeriod(
                planID: planID,
                periodIndex: periodIndex,
                dueAt: dueAt,
                principalMinorUnits: principalMinorUnits,
                interestMinorUnits: interestMinorUnits
            )
            model.uuid = uuid
            model.statusRawValue = statusRawValue
            model.settledAt = settledAt
            model.settledTransactionID = settledTransactionID
            model.isSoftDeleted = isSoftDeleted
            model.createdAt = createdAt
            model.updatedAt = updatedAt
            return model
        }
    }

    struct RecurringRuleRecord: Codable, Equatable {
        var uuid: UUID
        var name: String
        var frequencyRawValue: String
        var interval: Int
        var recurrenceDays: [Int]
        var startAt: Date
        var endAt: Date?
        var nextRunAt: Date
        var isPaused: Bool
        var templateKindRawValue: String
        var templateLedgerID: UUID?
        var templateAmountMinorUnits: Int
        var templateAccountID: UUID?
        var templateTargetAccountID: UUID?
        var templateCategoryID: UUID?
        var templateTagIDs: [UUID]
        var templateNote: String
        var isSoftDeleted: Bool
        var createdAt: Date
        var updatedAt: Date

        init(_ model: RecurringRule) {
            uuid = model.uuid
            name = model.name
            frequencyRawValue = model.frequencyRawValue
            interval = model.interval
            recurrenceDays = model.recurrenceDays
            startAt = model.startAt
            endAt = model.endAt
            nextRunAt = model.nextRunAt
            isPaused = model.isPaused
            templateKindRawValue = model.templateKindRawValue
            templateLedgerID = model.templateLedgerID
            templateAmountMinorUnits = model.templateAmountMinorUnits
            templateAccountID = model.templateAccountID
            templateTargetAccountID = model.templateTargetAccountID
            templateCategoryID = model.templateCategoryID
            templateTagIDs = model.templateTagIDs
            templateNote = model.templateNote
            isSoftDeleted = model.isSoftDeleted
            createdAt = model.createdAt
            updatedAt = model.updatedAt
        }

        func makeModel() -> RecurringRule {
            let model = RecurringRule(
                name: name,
                frequency: .daily,
                startAt: startAt,
                nextRunAt: nextRunAt,
                templateKind: .expense,
                templateAmountMinorUnits: templateAmountMinorUnits
            )
            model.uuid = uuid
            model.frequencyRawValue = frequencyRawValue
            model.interval = interval
            model.recurrenceDays = recurrenceDays
            model.endAt = endAt
            model.isPaused = isPaused
            model.templateKindRawValue = templateKindRawValue
            model.templateLedgerID = templateLedgerID
            model.templateAccountID = templateAccountID
            model.templateTargetAccountID = templateTargetAccountID
            model.templateCategoryID = templateCategoryID
            model.templateTagIDs = templateTagIDs
            model.templateNote = templateNote
            model.isSoftDeleted = isSoftDeleted
            model.createdAt = createdAt
            model.updatedAt = updatedAt
            return model
        }
    }

    struct ImportBatchRecord: Codable, Equatable {
        var uuid: UUID
        var fileName: String
        var contentHash: String
        var transactionCount: Int
        var importedAt: Date
        var isSoftDeleted: Bool
        var createdAt: Date
        var updatedAt: Date

        init(_ model: ImportBatch) {
            uuid = model.uuid
            fileName = model.fileName
            contentHash = model.contentHash
            transactionCount = model.transactionCount
            importedAt = model.importedAt
            isSoftDeleted = model.isSoftDeleted
            createdAt = model.createdAt
            updatedAt = model.updatedAt
        }

        func makeModel() -> ImportBatch {
            let model = ImportBatch(fileName: fileName, importedAt: importedAt)
            model.uuid = uuid
            model.contentHash = contentHash
            model.transactionCount = transactionCount
            model.isSoftDeleted = isSoftDeleted
            model.createdAt = createdAt
            model.updatedAt = updatedAt
            return model
        }
    }

    struct BalanceSnapshotRecord: Codable, Equatable {
        var uuid: UUID
        var accountID: UUID
        var snapshotAt: Date
        var balanceMinorUnits: Int
        var fxRateToBase: Decimal?
        var isSoftDeleted: Bool
        var createdAt: Date
        var updatedAt: Date

        init(_ model: BalanceSnapshot) {
            uuid = model.uuid
            accountID = model.accountID
            snapshotAt = model.snapshotAt
            balanceMinorUnits = model.balanceMinorUnits
            fxRateToBase = model.fxRateToBase
            isSoftDeleted = model.isSoftDeleted
            createdAt = model.createdAt
            updatedAt = model.updatedAt
        }

        func makeModel() -> BalanceSnapshot {
            let model = BalanceSnapshot(
                accountID: accountID,
                snapshotAt: snapshotAt,
                balanceMinorUnits: balanceMinorUnits
            )
            model.uuid = uuid
            model.fxRateToBase = fxRateToBase
            model.isSoftDeleted = isSoftDeleted
            model.createdAt = createdAt
            model.updatedAt = updatedAt
            return model
        }
    }

    struct AuditLogRecord: Codable, Equatable {
        var uuid: UUID
        var action: String
        var detail: String
        var occurredAt: Date
        var isSoftDeleted: Bool
        var createdAt: Date
        var updatedAt: Date

        init(_ model: AuditLog) {
            uuid = model.uuid
            action = model.action
            detail = model.detail
            occurredAt = model.occurredAt
            isSoftDeleted = model.isSoftDeleted
            createdAt = model.createdAt
            updatedAt = model.updatedAt
        }

        func makeModel() -> AuditLog {
            let model = AuditLog(action: action, detail: detail)
            model.uuid = uuid
            model.occurredAt = occurredAt
            model.isSoftDeleted = isSoftDeleted
            model.createdAt = createdAt
            model.updatedAt = updatedAt
            return model
        }
    }
}
