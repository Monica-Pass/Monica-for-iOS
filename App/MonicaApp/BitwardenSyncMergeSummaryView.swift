import MonicaSync
import SwiftUI

/// Bitwarden 预览/同步结果的字段级统计（新增、更新、冲突、删除、集合、组织条目）。
/// 只读展示，不触发任何写入；真正的提交仍由用户在“同步到本地”按钮上手动确认。
struct BitwardenSyncMergeSummaryView: View {
    let summary: BitwardenSyncPreviewSummary

    var body: some View {
        AndroidParityDivider()
        AndroidParityInfoRow(title: String(localized: "变更预览"), value: summary.countsSummary)
        if !summary.conflictFieldNames.isEmpty {
            AndroidParityInfoRow(
                title: String(localized: "冲突字段"),
                value: summary.conflictFieldNames.joined(separator: "、")
            )
        }
        if summary.organizationItemCount > 0 {
            AndroidParityInfoRow(
                title: String(localized: "组织条目"),
                value: String(localized: "\(summary.organizationItemCount) 个共享条目")
            )
        }
        if !summary.collectionNames.isEmpty {
            AndroidParityInfoRow(
                title: String(localized: "集合（只读）"),
                value: summary.collectionNames.joined(separator: "、")
            )
        }
        if summary.duplicateItemCount > 0 || summary.skippedItemCount > 0 {
            AndroidParityInfoRow(
                title: String(localized: "已跳过"),
                value: String(localized: "重复 \(summary.duplicateItemCount) 个，不在集合内 \(summary.skippedItemCount) 个")
            )
        }
    }
}
