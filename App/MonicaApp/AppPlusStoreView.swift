//
//  AppPlusStoreView.swift
//  Monica
//
//  设置页的 Monica Plus 入口与支持者页面。
//
//  这里刻意不出现「解锁 / 需要购买」的措辞：Monica Plus 是支持作者的自愿赞助，
//  购买只点亮支持者徽章，所有功能永久免费。
//

import SwiftUI

struct AppPlusSettingsView: View {
    let session: AppSessionModel

    @State private var isStorePresented = false

    private var status: AppPlusEntitlementStatusRow {
        session.plusEntitlementStatusRow
    }

    var body: some View {
        AndroidParitySection(title: "Monica Plus") {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                HStack(alignment: .top, spacing: 12) {
                    AndroidParityIconTile(
                        systemImage: status.systemImage,
                        fill: session.isPlusSupporter
                            ? AndroidParityPalette.primaryContainer
                            : AndroidParityPalette.surfaceVariant,
                        tint: session.isPlusSupporter
                            ? AndroidParityPalette.primary
                            : AndroidParityPalette.textSecondary
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(status.title)
                            .font(.headline)
                            .foregroundStyle(AndroidParityPalette.textPrimary)
                        Text(status.value)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(
                                session.isPlusSupporter
                                    ? AndroidParityPalette.primary
                                    : AndroidParityPalette.textSecondary
                            )
                        Text(status.detail)
                            .font(.footnote)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                AndroidParityDivider()

                ForEach(session.plusFeatureRows) { row in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: row.systemImage)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AndroidParityPalette.primary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AndroidParityPalette.textPrimary)
                            Text(row.detail)
                                .font(.caption)
                                .foregroundStyle(AndroidParityPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Text(row.value)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AndroidParityPalette.primary)
                    }
                }

                Button {
                    isStorePresented = true
                } label: {
                    Label("支持作者", systemImage: "heart")
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .filled))

                Text("支持完全自愿；不购买也能使用全部功能。")
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $isStorePresented) {
            NavigationStack {
                AppPlusStoreView(session: session)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }
}

struct AppPlusStoreView: View {
    let session: AppSessionModel

    @Environment(\.dismiss) private var dismiss

    private var status: AppPlusEntitlementStatusRow {
        session.plusEntitlementStatusRow
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                supporterCard
                productsCard
                freeFeaturesCard
                restoreCard
                Text("支持完全自愿。Monica 的所有功能永久免费，购买不会改变任何功能的可用性。")
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            .padding(16)
        }
        .background(AndroidParityPalette.surfaceVariant.opacity(0.35))
        .navigationTitle("Monica Plus")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    dismiss()
                }
            }
        }
        .refreshable {
            await session.loadPlusProducts()
            await session.refreshPlusEntitlement()
        }
        .task {
            await session.loadPlusProducts()
            await session.refreshPlusEntitlement()
        }
    }

    private var supporterCard: some View {
        AndroidParityCard {
            HStack(alignment: .top, spacing: 12) {
                AndroidParityIconTile(
                    systemImage: status.systemImage,
                    fill: session.isPlusSupporter
                        ? AndroidParityPalette.primaryContainer
                        : AndroidParityPalette.surfaceVariant,
                    tint: session.isPlusSupporter
                        ? AndroidParityPalette.primary
                        : AndroidParityPalette.textSecondary
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.isPlusSupporter ? "支持者徽章已点亮" : "支持作者，所有功能永久免费")
                        .font(.headline)
                        .foregroundStyle(AndroidParityPalette.textPrimary)
                    Text(status.detail)
                        .font(.footnote)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if session.isPlusSupporter {
                Label("感谢你的支持！", systemImage: "heart.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.primary)
            }
        }
    }

    private var productsCard: some View {
        AndroidParityCard {
            Text("赞助商品")
                .font(.headline)
                .foregroundStyle(AndroidParityPalette.textPrimary)
            Text("商品名称与价格来自 App Store；购买只点亮支持者徽章，不会解锁任何功能。")
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            switch session.plusProductLoadState {
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在从 App Store 加载商品…")
                        .font(.footnote)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
            case .unavailable(let message):
                Text(message)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("所有功能仍然永久免费，可稍后下拉重试。")
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .loaded:
                ForEach(session.plusProducts) { product in
                    productRow(product)
                }
            }

            purchaseStateMessage
        }
    }

    private func productRow(_ product: AppPlusProductInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(product.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                Spacer(minLength: 12)
                Text(product.displayPrice)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.primary)
            }
            if !product.description.isEmpty {
                Text(product.description)
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                Task {
                    await session.purchasePlus(productID: product.id)
                }
            } label: {
                Label(session.isPlusSupporter ? "再次支持" : "支持作者", systemImage: "heart")
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .filled))
            .disabled(session.plusPurchaseState.isRunning)
        }
    }

    @ViewBuilder
    private var purchaseStateMessage: some View {
        switch session.plusPurchaseState {
        case .idle:
            EmptyView()
        case .purchasing:
            Label("正在与 App Store 完成购买…", systemImage: "hourglass")
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
        case .restoring:
            Label("正在恢复购买…", systemImage: "hourglass")
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
        case .succeeded:
            Label("已确认支持者身份，感谢你的支持！", systemImage: "checkmark.seal.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.primary)
        case .userCancelled:
            Label("已取消购买，所有功能仍可正常使用。", systemImage: "xmark.circle")
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
        case .pending:
            Label(
                "购买正在等待 App Store 批准（例如家长同意）。批准后会自动更新，无需重复购买。",
                systemImage: "clock"
            )
            .font(.footnote)
            .foregroundStyle(AndroidParityPalette.textSecondary)
        case .nothingToRestore:
            Label("当前 Apple ID 没有可恢复的 Monica Plus 购买。", systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
        }
    }

    private var freeFeaturesCard: some View {
        AndroidParityCard {
            Text("所有功能永久免费")
                .font(.headline)
                .foregroundStyle(AndroidParityPalette.textPrimary)
            ForEach(session.plusFeatureRows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.title)
                            .font(.subheadline)
                            .foregroundStyle(AndroidParityPalette.textPrimary)
                        Spacer(minLength: 12)
                        Text(row.value)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AndroidParityPalette.primary)
                    }
                    Text(row.detail)
                        .font(.caption)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var restoreCard: some View {
        AndroidParityCard {
            Text("恢复购买")
                .font(.headline)
                .foregroundStyle(AndroidParityPalette.textPrimary)
            Text("更换设备或重装后，用同一个 Apple ID 恢复支持者身份；不会恢复或影响你的密码库。")
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task {
                    await session.restorePlusPurchases()
                }
            } label: {
                Label("恢复购买", systemImage: "arrow.clockwise")
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
            .disabled(session.plusPurchaseState.isRunning)
        }
    }
}
