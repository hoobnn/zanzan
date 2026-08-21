import SwiftUI

/// 业务语义色：收入绿、支出红、转账暖金；普通交互保持中性。
extension Color {
    static let zanzanWarm = Color(red: 0.95, green: 0.70, blue: 0.25)
    static let zanzanExpense = Color(red: 0.86, green: 0.22, blue: 0.28)
    static let zanzanIncome = Color(red: 0.07, green: 0.59, blue: 0.43)
    static let zanzanCoral = Color(red: 0.96, green: 0.47, blue: 0.43)
    static let zanzanMint = Color(red: 0.27, green: 0.76, blue: 0.63)
    static let zanzanSky = Color(red: 0.31, green: 0.62, blue: 0.94)
    static let zanzanSun = Color(red: 0.98, green: 0.76, blue: 0.27)
    static let zanzanLilac = Color(red: 0.65, green: 0.50, blue: 0.91)

    static func zanzan(token: String) -> Color {
        switch token {
        case "green": .green
        case "orange": .orange
        case "red": .red
        case "purple": .purple
        case "pink": .pink
        case "teal": .teal
        case "gray": .gray
        default: .blue
        }
    }
}
