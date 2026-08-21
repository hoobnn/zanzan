import SwiftUI

struct SettingsHomeView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 280 : 150),
                spacing: 8
            ),
        ]
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("账户与分类")
                        .font(.subheadline)
                        .bold()
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: columns, spacing: 8) {
                        NavigationLink {
                            LedgersListView()
                        } label: {
                            ZanzanSettingsLabel(title: "账本管理", systemImage: "books.vertical.fill")
                        }
                        .accessibilityIdentifier("settings.link.ledgers")

                        NavigationLink {
                            AccountsListView()
                        } label: {
                            ZanzanSettingsLabel(title: "账户管理", systemImage: "creditcard.fill")
                        }
                        .accessibilityIdentifier("settings.link.accounts")

                        NavigationLink {
                            CategoriesHomeView()
                        } label: {
                            ZanzanSettingsLabel(title: "分类管理", systemImage: "square.grid.2x2.fill")
                        }
                        .accessibilityIdentifier("settings.link.categories")

                        NavigationLink {
                            TagsHomeView()
                        } label: {
                            ZanzanSettingsLabel(title: "标签管理", systemImage: "tag.fill")
                        }
                        .accessibilityIdentifier("settings.link.tags")
                    }
                }
                .padding(12)
                .zanzanSketchCard(tint: .zanzanSky)

                VStack(alignment: .leading, spacing: 8) {
                    Text("计划与进阶")
                        .font(.subheadline)
                        .bold()
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: columns, spacing: 8) {
                        NavigationLink {
                            BudgetsHomeView()
                        } label: {
                            ZanzanSettingsLabel(title: "预算", systemImage: "gauge.with.dots.needle.33percent")
                        }
                        .accessibilityIdentifier("settings.link.budgets")

                        NavigationLink {
                            ReimbursementsHomeView()
                        } label: {
                            ZanzanSettingsLabel(title: "报销与退款", systemImage: "arrow.uturn.backward.circle.fill")
                        }
                        .accessibilityIdentifier("settings.link.reimbursements")

                        NavigationLink {
                            RecurringRulesHomeView()
                        } label: {
                            ZanzanSettingsLabel(title: "周期记账", systemImage: "repeat.circle.fill")
                        }
                        .accessibilityIdentifier("settings.link.recurring")

                        NavigationLink {
                            InstallmentsHomeView()
                        } label: {
                            ZanzanSettingsLabel(title: "分期与贷款", systemImage: "calendar.badge.clock")
                        }
                        .accessibilityIdentifier("settings.link.installments")

                        NavigationLink {
                            CreditPoolsHomeView()
                        } label: {
                            ZanzanSettingsLabel(title: "授信池", systemImage: "creditcard.and.123")
                        }
                        .accessibilityIdentifier("settings.link.creditPools")
                    }
                }
                .padding(12)
                .zanzanSketchCard(tint: .zanzanLilac)

                VStack(alignment: .leading, spacing: 8) {
                    Text("数据")
                        .font(.subheadline)
                        .bold()
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: columns, spacing: 8) {
                        NavigationLink {
                            DataTransferView()
                        } label: {
                            ZanzanSettingsLabel(title: "导入导出", systemImage: "arrow.up.arrow.down.circle.fill")
                        }
                        .accessibilityIdentifier("settings.link.dataTransfer")

                        NavigationLink {
                            DataMaintenanceView()
                        } label: {
                            ZanzanSettingsLabel(title: "数据维护", systemImage: "wrench.and.screwdriver.fill")
                        }
                        .accessibilityIdentifier("settings.link.maintenance")

                        NavigationLink {
                            RecentlyDeletedView()
                        } label: {
                            ZanzanSettingsLabel(title: "最近删除", systemImage: "trash.circle.fill")
                        }
                        .accessibilityIdentifier("settings.link.recentlyDeleted")
                    }
                }
                .padding(12)
                .zanzanSketchCard(tint: .zanzanMint)

                VStack(alignment: .leading, spacing: 8) {
                    Text("个性化")
                        .font(.subheadline)
                        .bold()
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: columns, spacing: 8) {
                        NavigationLink {
                            AppearanceSettingsView()
                        } label: {
                            ZanzanSettingsLabel(title: "外观与语言", systemImage: "paintpalette.fill")
                        }
                        .accessibilityIdentifier("settings.link.appearance")

                        NavigationLink {
                            AppIconSettingsView()
                        } label: {
                            ZanzanSettingsLabel(title: "应用图标", systemImage: "app.badge.fill")
                        }
                        .accessibilityIdentifier("settings.link.appIcon")
                    }
                }
                .padding(12)
                .zanzanSketchCard(tint: .zanzanCoral)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .accessibilityIdentifier("screen.settings")
        .zanzanSketchPageBackground()
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }
}

#Preview {
    NavigationStack { SettingsHomeView() }
}
