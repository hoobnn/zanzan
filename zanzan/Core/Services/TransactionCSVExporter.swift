import Foundation
import SwiftData

/// CSV 列约定（数据库设计文档未规定 CSV 格式，此处自定义，导入导出共用一套）：
///
///     日期,类型,金额,分类,账户,转入账户,手续费,备注,币种,汇率,到账金额
///
/// - 编码遵循 RFC 4180：字段含逗号/引号/换行时整体加双引号，内部 `"` 写作 `""`
/// - 日期：`yyyy-MM-dd HH:mm:ss`（设备当前时区，见 §4 日历口径；导入另接受 `yyyy-MM-dd`）
/// - 类型：`支出` / `收入` / `转账`
/// - 金额/手续费：十进制元字符串（如 `25.5`），**不允许千分位分隔符**；手续费为 0 时导出空串
/// - 分类：收支必填分类名，转账留空；转入账户：仅转账填写
/// - 币种：流水记账币种（§5.4：收支 = 账户币种，转账 = 转出方币种），空按 CNY
/// - 汇率：`fxRateToBase` 十进制串；本位币（CNY）行恒空，外币行必填且 > 0
/// - 到账金额：跨币种转账的转入方到账额（元串，转入账户币种计）；其余行恒空
/// - 兼容：不含后三列的旧 8 列文件按 CNY 读入
enum TransactionCSV {
    /// 旧 8 列格式（多币种列上线前导出的文件，导入保持兼容）
    static let legacyHeaderColumns = ["日期", "类型", "金额", "分类", "账户", "转入账户", "手续费", "备注"]
    static let legacyColumnCount = 8
    static let headerColumns = legacyHeaderColumns + ["币种", "汇率", "到账金额"]
    static let columnCount = 11

    static let kindLabels: [TransactionKind: String] = [.expense: "支出", .income: "收入", .transfer: "转账"]
    static let kindByLabel: [String: TransactionKind] = ["支出": .expense, "收入": .income, "转账": .transfer]

    /// 完整时间格式（导出用）
    static let dateFormatter: DateFormatter = makeFormatter("yyyy-MM-dd HH:mm:ss")
    /// 仅日期格式（导入兼容）
    static let shortDateFormatter: DateFormatter = makeFormatter("yyyy-MM-dd")

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format // 时区取设备当前时区（§4 日历口径）
        return formatter
    }

    /// RFC 4180 字段转义：含分隔符/引号/换行时加引号，内部引号翻倍
    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// RFC 4180 解析：支持带引号字段、`""` 转义、字段内换行、CRLF/LF 行尾。
    /// 外部数据不可信：引号位置非法/未闭合一律抛错，绝不静默猜测。
    static func parse(_ text: String) throws -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var isInQuotes = false
        var isAwaitingSeparator = false // 引号字段刚闭合，后面只允许 , 或行尾

        func endField() {
            record.append(field)
            field = ""
            isAwaitingSeparator = false
        }
        func endRecord() {
            // 空白行（无任何字段与内容）跳过
            if record.isEmpty && field.isEmpty && !isAwaitingSeparator { return }
            endField()
            records.append(record)
            record = []
        }

        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if isInQuotes {
                if char == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"") // "" → 字面引号
                        index = next
                    } else {
                        isInQuotes = false
                        isAwaitingSeparator = true
                    }
                } else {
                    field.append(char)
                }
            } else {
                switch char {
                case "\"":
                    guard field.isEmpty, !isAwaitingSeparator else { throw TransactionCSVError.malformed }
                    isInQuotes = true
                case ",":
                    endField()
                case "\n":
                    endRecord()
                case "\r":
                    break // CRLF 的 \r 忽略，行尾统一由 \n 触发
                default:
                    guard !isAwaitingSeparator else { throw TransactionCSVError.malformed }
                    field.append(char)
                }
            }
            index = text.index(after: index)
        }
        guard !isInQuotes else { throw TransactionCSVError.malformed } // 引号未闭合
        endRecord() // 末行无换行符时补收
        return records
    }

    /// 严格版金额解析（元串 → 分）：白名单/量级上限逻辑已下沉到 `MoneyAmount`（唯一实现），此处纯转发。
    static func minorUnits(fromCSVAmount string: String) -> Int? {
        MoneyAmount.minorUnits(fromDecimalString: string)
    }

    /// 严格版汇率解析：复用 `MoneyAmount.strictDecimal`（拒逗号/科学计数法等静默错值），
    /// Decimal 定点不经 Double；汇率不是金额，小数位数不受两位限制
    static func decimal(fromCSVRate string: String) -> Decimal? {
        MoneyAmount.strictDecimal(from: string)
    }
}

enum TransactionCSVError: LocalizedError {
    case malformed

    var errorDescription: String? {
        switch self {
        case .malformed: String(localized: "CSV 格式不正确（引号未闭合或位置非法）")
        }
    }
}

/// 流水 CSV 导出（设计文档 §5.12 配套读路径）。列约定见 `TransactionCSV`。
struct TransactionCSVExporter {
    let context: ModelContext

    /// 导出指定账本、时间范围（闭区间 [startDate, endDate]）内的活跃流水，按发生时间升序。
    /// 软删流水不导出；kind 语义未知的流水跳过（§4 前向兼容：未知数据只读不搬运）。
    func exportCSV(ledgerID: UUID, from startDate: Date, to endDate: Date) throws -> String {
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate {
                !$0.isSoftDeleted && $0.ledgerID == ledgerID
                    && $0.occurredAt >= startDate && $0.occurredAt <= endDate
            },
            sortBy: [SortDescriptor(\.occurredAt, order: .forward)]
        )
        let transactions = try context.fetch(descriptor)

        var lines = [TransactionCSV.headerColumns.joined(separator: ",")]
        for tx in transactions {
            guard let kind = tx.kind, let kindLabel = TransactionCSV.kindLabels[kind] else { continue }
            // Decimal 描述即十进制串；nil（本位币行/非跨币种转账）导出为空
            let fxRateField: String = tx.fxRateToBase.map { "\($0)" } ?? ""
            let targetAmountField: String = tx.targetAmountMinorUnits
                .map { MoneyAmount.decimalString(fromMinorUnits: $0) } ?? ""
            let fields = [
                TransactionCSV.dateFormatter.string(from: tx.occurredAt),
                kindLabel,
                MoneyAmount.decimalString(fromMinorUnits: tx.amountMinorUnits),
                tx.category?.name ?? "",
                tx.account?.name ?? "",
                tx.targetAccount?.name ?? "",
                tx.feeMinorUnits > 0 ? MoneyAmount.decimalString(fromMinorUnits: tx.feeMinorUnits) : "",
                tx.note,
                tx.currencyCode,
                fxRateField,
                targetAmountField,
            ]
            lines.append(fields.map(TransactionCSV.escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
