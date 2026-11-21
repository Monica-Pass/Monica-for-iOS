import MonicaCore
import SwiftUI

/// 条目图标选择器。
///
/// 存的是稳定资源 ID（`catalog:bank` / `sf:key.fill`），不是本地化名称；
/// 渲染时由 `ItemIcon.resolvedSystemName` 解析，未知 ID 回退到 `key.fill`。
struct AppItemIconPickerView: View {
    @Binding var icon: String?
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    defaultRow
                    section(title: String(localized: "分类图标"), items: ItemIconCatalog.entries.map { entry in
                        AppItemIconChoice(
                            id: "catalog:\(entry.id)",
                            symbol: entry.symbolName,
                            label: entry.displayName
                        )
                    })
                    section(title: String(localized: "更多符号"), items: ItemIconCatalog.extraSymbols.map { name in
                        AppItemIconChoice(id: "sf:\(name)", symbol: name, label: name)
                    })
                }
                .padding(18)
            }
            .background(AndroidParityPalette.background.ignoresSafeArea())
            .navigationTitle(String(localized: "条目图标"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
            }
        }
    }

    private var defaultRow: some View {
        Button {
            icon = nil
            dismiss()
        } label: {
            HStack(spacing: 14) {
                AndroidParityIconTile(systemImage: ItemIcon.defaultSymbol(forKind: "login"))
                VStack(alignment: .leading, spacing: 4) {
                    Text("默认图标")
                        .font(.subheadline.weight(.semibold))
                    Text("按条目类型自动选择（登录条目使用钥匙）。")
                        .font(.caption)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
                Spacer()
                if icon == nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AndroidParityPalette.primary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                AndroidParityPalette.surfaceVariant.opacity(icon == nil ? 0.9 : 0.5),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func section(title: String, items: [AppItemIconChoice]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(items) { item in
                    Button {
                        icon = item.id
                        dismiss()
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(AndroidParityPalette.textPrimary)
                                .frame(width: 44, height: 44)
                                .background(
                                    AndroidParityPalette.surface,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                            Text(item.label)
                                .font(.caption2)
                                .foregroundStyle(AndroidParityPalette.textSecondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            icon == item.id ? AndroidParityPalette.primaryContainer : Color.clear,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(
                                    icon == item.id ? AndroidParityPalette.primary : AndroidParityPalette.outline,
                                    lineWidth: icon == item.id ? 1.5 : 1
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(item.label))
                    .accessibilityAddTraits(icon == item.id ? [.isSelected] : [])
                }
            }
        }
    }
}

private struct AppItemIconChoice: Identifiable {
    let id: String
    let symbol: String
    let label: String
}
