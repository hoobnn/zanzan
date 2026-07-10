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
        guard let limit = MoneyAmount.minorUnits(fromDecimalString: totalLimitString), limit > 0 else {
            throw CreditPoolDraftError.invalidTotalLimit
        }
        return Validated(
            name: name,
            totalLimitMinorUnits: limit,
            currencyCode: currencyCode,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
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
    case invalidTotalLimit

    var errorDescription: String? {
        switch self {
        case .emptyName: String(localized: "授信池名称不能为空")
        case .invalidTotalLimit: String(localized: "总授信额度须为正数金额")
        }
    }
}

/// 授信池写路径命令（设计文档 5.8）。不变量：仅 credit 类账户可入池、
/// 成员币种与池一致、软删池自动解绑全部成员卡。
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
        try context.save()
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
        try context.save()
    }

    /// 软删池：成员卡 creditPoolID 自动置 nil（解绑回独立额度，不动卡本身）。
    func softDeletePool(uuid: UUID) throws {
        let pool = try fetchActivePool(uuid)
        for member in try activeMembers(of: uuid) {
            member.creditPoolID = nil
            member.updatedAt = .now
        }
        pool.isSoftDeleted = true
        pool.updatedAt = .now
        try context.save()
    }

    /// 绑定成员卡：仅 credit 类、币种与池一致；一卡至多一池，重复绑定即改绑。
    func bindCard(accountUUID: UUID, toPool poolUUID: UUID) throws {
        let pool = try fetchActivePool(poolUUID)
        let account = try fetchActiveAccount(accountUUID)
        guard account.kind == .credit else { throw CreditPoolServiceError.notCreditAccount }
        guard account.currencyCode == pool.currencyCode else { throw CreditPoolServiceError.currencyMismatch }
        account.creditPoolID = poolUUID
        account.updatedAt = .now
        try context.save()
    }

    /// 解绑成员卡（回独立额度）。
    func unbindCard(accountUUID: UUID) throws {
        let account = try fetchActiveAccount(accountUUID)
        account.creditPoolID = nil
        account.updatedAt = .now
        try context.save()
    }

    // MARK: - 私有

    private func fetchActivePool(_ uuid: UUID) throws -> CreditPool {
        let descriptor = FetchDescriptor<CreditPool>(
            predicate: #Predicate { !$0.isSoftDeleted && $0.uuid == uuid }
        )
        guard let pool = try context.fetch(descriptor).first else {
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
        case .poolNotFound: String(localized: "授信池不存在或已删除")
        case .accountNotFound: String(localized: "账户不存在或已删除")
        case .notCreditAccount: String(localized: "仅信用卡类账户可加入授信池")
        case .currencyMismatch: String(localized: "成员卡币种须与授信池一致")
        }
    }
}
