import Foundation
import SwiftData

/// 授信池表单草稿——入口校验 + 归一化（设计文档 5.8）。
/// ponytail: 与 Service 同文件（本切片交付物锁定文件清单）；UI 表单切片若需要可迁至 Core/Drafts。
struct CreditPoolDraft {
    var name: String = ""
    var totalLimitString: String = ""
    var currencyCode: String = "CNY"
    var note: String = ""

    struct Validated {
        let name: String
        let totalLimitMinorUnits: Int
        let currencyCode: String
        let note: String
    }

    func validated() throws -> Validated {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CreditPoolDraftError.emptyName }
        guard name.count <= DraftLimits.maxNameLength else { throw CreditPoolDraftError.nameTooLong }
        guard let limit = MoneyAmount.minorUnits(fromDecimalString: totalLimitString), limit > 0 else {
            throw CreditPoolDraftError.invalidTotalLimit
        }
        let currencyCode = currencyCode.trimmingCharacters(in: .whitespaces).uppercased()
        guard currencyCode.count == 3,
              currencyCode.allSatisfy({ ("A"..."Z").contains($0) }) else {
            throw CreditPoolDraftError.invalidCurrencyCode
        }
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note.count <= DraftLimits.maxNoteLength else { throw CreditPoolDraftError.noteTooLong }
        return Validated(
            name: name,
            totalLimitMinorUnits: limit,
            currencyCode: currencyCode,
            note: note
        )
    }
}

extension CreditPoolDraft {
    /// 编辑表单回填。
    init(pool: CreditPool) {
        self.init()
        name = pool.name
        totalLimitString = MoneyAmount.decimalString(fromMinorUnits: pool.totalLimitMinorUnits)
        currencyCode = pool.currencyCode
        note = pool.note
    }
}

enum CreditPoolDraftError: LocalizedError {
    case emptyName
    case nameTooLong
    case noteTooLong
    case invalidTotalLimit
    case invalidCurrencyCode

    var errorDescription: String? {
        switch self {
        case .emptyName: ZanzanLocalization.string( "授信池名称不能为空")
        case .nameTooLong: ZanzanLocalization.string( "授信池名称不能超过 \(DraftLimits.maxNameLength) 字")
        case .noteTooLong: ZanzanLocalization.string( "备注不能超过 \(DraftLimits.maxNoteLength) 字")
        case .invalidTotalLimit: ZanzanLocalization.string( "总授信额度须为正数金额")
        case .invalidCurrencyCode: ZanzanLocalization.string( "币种代码须为 3 位大写字母（ISO 4217）")
        }
    }
}

/// 授信池写路径命令（设计文档 5.8）。不变量：仅 credit 类账户可入池、
/// 成员币种与池一致；软删保留成员关系，确保撤销能精确恢复。
struct CreditPoolService {
    let context: ModelContext

    @discardableResult
    func createPool(_ draft: CreditPoolDraft) throws -> CreditPool {
        let v = try draft.validated()
        let activeCount = try context.fetchCount(
            FetchDescriptor<CreditPool>(predicate: #Predicate { !$0.isSoftDeleted })
        )
        let pool = CreditPool(name: v.name, totalLimitMinorUnits: v.totalLimitMinorUnits)
        pool.currencyCode = v.currencyCode
        pool.note = v.note
        pool.sortOrder = activeCount
        context.insert(pool)
        try context.zanzanSave()
        return pool
    }

    func updatePool(uuid: UUID, draft: CreditPoolDraft) throws {
        let v = try draft.validated()
        let pool = try fetchActivePool(uuid)
        // 改币种时须与全部活跃成员卡一致（5.8 命令层校验）
        if v.currencyCode != pool.currencyCode {
            let mismatched = try activeMembers(of: uuid).contains { $0.currencyCode != v.currencyCode }
            guard !mismatched else { throw CreditPoolServiceError.currencyMismatch }
        }
        pool.name = v.name
        pool.totalLimitMinorUnits = v.totalLimitMinorUnits
        pool.currencyCode = v.currencyCode
        pool.note = v.note
        pool.updatedAt = .now
        try context.zanzanSave()
    }

    /// 软删池：保留成员卡的弱引用。读路径忽略软删池并按独立额度兜底，
    /// 撤销后原成员关系自然恢复，不丢用户数据。
    func softDeletePool(uuid: UUID) throws {
        let pool = try fetchActivePool(uuid)
        pool.isSoftDeleted = true
        pool.updatedAt = .now
        try context.zanzanSave()
    }

    /// 撤销软删（§4 撤销恢复按相反方向执行）：成员关系未被破坏，恢复后原样生效。
    func undoSoftDeletePool(uuid: UUID) throws {
        let pool = try fetchPool(uuid, includeDeleted: true)
        guard pool.isSoftDeleted else { return }
        pool.isSoftDeleted = false
        pool.updatedAt = .now
        try context.zanzanSave()
    }

    /// 绑定成员卡：仅 credit 类、币种与池一致；一卡至多一池，重复绑定即改绑。
    func bindCard(accountUUID: UUID, toPool poolUUID: UUID) throws {
        let pool = try fetchActivePool(poolUUID)
        let account = try fetchActiveAccount(accountUUID)
        guard account.kind == .credit else { throw CreditPoolServiceError.notCreditAccount }
        guard account.currencyCode == pool.currencyCode else { throw CreditPoolServiceError.currencyMismatch }
        account.creditPoolID = poolUUID
        account.updatedAt = .now
        try context.zanzanSave()
    }

    /// 解绑成员卡（回独立额度）。
    func unbindCard(accountUUID: UUID) throws {
        let account = try fetchActiveAccount(accountUUID)
        account.creditPoolID = nil
        account.updatedAt = .now
        try context.zanzanSave()
    }

    // MARK: - 私有

    private func fetchActivePool(_ uuid: UUID) throws -> CreditPool {
        try fetchPool(uuid, includeDeleted: false)
    }

    private func fetchPool(_ uuid: UUID, includeDeleted: Bool) throws -> CreditPool {
        let predicate: Predicate<CreditPool> = includeDeleted
            ? #Predicate { $0.uuid == uuid }
            : #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        guard let pool = try context.fetch(FetchDescriptor<CreditPool>(predicate: predicate)).first else {
            throw CreditPoolServiceError.poolNotFound
        }
        return pool
    }

    private func fetchActiveAccount(_ uuid: UUID) throws -> Account {
        let descriptor = FetchDescriptor<Account>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        )
        guard let account = try context.fetch(descriptor).first else {
            throw CreditPoolServiceError.accountNotFound
        }
        return account
    }

    private func activeMembers(of poolUUID: UUID) throws -> [Account] {
        try context.fetch(
            FetchDescriptor<Account>(
                predicate: #Predicate { !$0.isSoftDeleted && $0.creditPoolID == poolUUID }
            )
        )
    }
}

enum CreditPoolServiceError: LocalizedError {
    case poolNotFound
    case accountNotFound
    case notCreditAccount
    case currencyMismatch

    var errorDescription: String? {
        switch self {
        case .poolNotFound: ZanzanLocalization.string( "授信池不存在或已删除")
        case .accountNotFound: ZanzanLocalization.string( "账户不存在或已删除")
        case .notCreditAccount: ZanzanLocalization.string( "仅信用卡类账户可加入授信池")
        case .currencyMismatch: ZanzanLocalization.string( "成员卡币种须与授信池一致")
        }
    }
}
