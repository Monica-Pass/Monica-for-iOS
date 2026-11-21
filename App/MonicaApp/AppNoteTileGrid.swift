import MonicaCore
import MonicaStorage
import SwiftUI

// MARK: - 布局偏好（#152）

/// 笔记列表的两种布局。默认列表，与改动前的界面保持一致。
enum AppNoteListLayout: String, CaseIterable, Sendable {
    case list
    case grid

    /// 布局偏好只存这一条原始值；非法值一律回退到列表。
    static let userDefaultsKey = "monica.notes.layout"

    init(persistedValue: String?) {
        guard let persistedValue else {
            self = .list
            return
        }
        let normalized = persistedValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self = AppNoteListLayout(rawValue: normalized) ?? .list
    }
}

/// 布局偏好的持久化入口。测试可以用独立 suite 的 `UserDefaults` 构造，避免污染真实偏好。
final class UserDefaultsNoteListLayoutStore: @unchecked Sendable {
    static let shared = UserDefaultsNoteListLayoutStore()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadLayout() -> AppNoteListLayout {
        AppNoteListLayout(persistedValue: defaults.string(forKey: AppNoteListLayout.userDefaultsKey))
    }

    func saveLayout(_ layout: AppNoteListLayout) {
        defaults.set(layout.rawValue, forKey: AppNoteListLayout.userDefaultsKey)
    }
}

// MARK: - 瓷砖卡片

/// 瓷砖卡片要显示的全部内容。由列表页从 `LocalNoteEntry` 生成，卡片本身只负责排版。
struct AppNoteTileContent: Equatable, Sendable {
    let title: String
    let summary: String
    let imageCount: Int
    let updatedAt: Date?
}

struct AppNoteTileCard: View {
    let content: AppNoteTileContent

    @Environment(\.paritySpacingScale) private var spacingScale

    var body: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.78), cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 8 * spacingScale) {
                Text(content.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if !content.summary.isEmpty {
                    Text(content.summary)
                        .font(.subheadline)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                HStack(alignment: .center, spacing: 8 * spacingScale) {
                    if let updatedAtText {
                        Text(updatedAtText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    if content.imageCount > 0 {
                        imageBadge
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 96 * spacingScale, alignment: .topLeading)
        }
        // 整张卡片是一个无障碍元素：VoiceOver 一次读完标题、更新时间与图片数，
        // 不把摘要文字或角标拆成独立的焦点。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabelText))
    }

    private var updatedAtText: String? {
        guard let updatedAt = content.updatedAt else {
            return nil
        }
        return String(localized: "更新于 \(dateText(for: updatedAt))")
    }

    private var imageBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "photo")
                .font(AndroidParityTypography.smallIcon(weight: .semibold))
            Text(verbatim: "\(content.imageCount)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(AndroidParityPalette.textPrimary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(AndroidParityPalette.secondaryContainer, in: Capsule())
        .accessibilityHidden(true)
    }

    private var accessibilityLabelText: String {
        guard let updatedAt = content.updatedAt else {
            return content.imageCount > 0
                ? String(localized: "\(content.title)，含 \(content.imageCount) 张图片")
                : content.title
        }
        let day = dateText(for: updatedAt)
        return content.imageCount > 0
            ? String(localized: "\(content.title)，更新于 \(day)，含 \(content.imageCount) 张图片")
            : String(localized: "\(content.title)，更新于 \(day)")
    }

    private func dateText(for date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: - 自适应网格

/// `LazyVGrid` 自适应列：列宽跟着 Dynamic Type 走，字号变大时自动减少列数而不是挤压文字。
struct AppNoteTileGrid<Entry: Identifiable, Tile: View>: View {
    let entries: [Entry]
    @ViewBuilder let tile: (Entry) -> Tile

    @ScaledMetric(relativeTo: .body) private var minimumColumnWidth: CGFloat = 164

    private let spacing: CGFloat = 14

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: minimumColumnWidth), spacing: spacing, alignment: .top)
            ],
            alignment: .leading,
            spacing: spacing
        ) {
            ForEach(entries) { entry in
                tile(entry)
            }
        }
    }
}
