import Foundation

/// Draft 层集中边界常量——全部 Draft 复用，一处可调。
/// 超长/越界一律 fail fast 抛错（系统边界不截断、不静默修正）。
nonisolated enum DraftLimits {  // nonisolated：错误文案（LocalizedError）在非隔离上下文引用
    /// 名称类字段（账本/账户/分类/标签/计划名，含账户 subtitle）上限（字符数）
    static let maxNameLength = 100
    /// 备注类字段上限（字符数）
    static let maxNoteLength = 500

    /// 业务时间合法区间：1970-01-01 ..< 2100-01-01（UTC）。
    /// 固定区间免时钟注入；防公元 4000 年流水永久隐身却计余额。
    static let occurredAtRange: Range<Date> =
        Date(timeIntervalSince1970: 0) ..< Date(timeIntervalSince1970: 4_102_444_800)
    /// DatePicker 用闭区间（半开区间的上界前一秒）
    static let occurredAtPickerRange: ClosedRange<Date> =
        occurredAtRange.lowerBound ... occurredAtRange.upperBound.addingTimeInterval(-1)

    /// 预算年份合法区间
    static let budgetYearRange = 2000...2100
    /// 周期记账重复间隔上限
    static let maxRecurrenceInterval = 365
    /// 分期总期数上限（50 年月供）
    static let maxInstallmentPeriods = 600
    /// 年利率上限（基点，= 1000%）
    static let maxAnnualRateBps = 100_000
}
