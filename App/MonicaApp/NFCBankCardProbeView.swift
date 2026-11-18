import CoreNFC
import MonicaCore
import SwiftUI

/// 银行卡 NFC 诊断的 App 侧适配层。
///
/// 设计约束：
/// - 默认关闭，必须由用户显式打开 feature flag 才能启动会话；
/// - 只读取“标签家族 / NDEF 记录类型与数量 / 系统选中的非支付 AID”这类非敏感字段；
/// - 不发送 APDU，不解析记录内容，不展示、保存或上传卡号、有效期、CVV、硬件 UID；
/// - 所有错误只保留 `NFCCardProbeFailure` 的类别与稳定诊断码。
@MainActor
final class NFCBankCardProbeModel: ObservableObject {
    enum RunState: Equatable {
        case idle
        case scanning(NFCCardProbeMode)
        case finished(NFCCardProbeTagFacts)
        case failed(NFCCardProbeFailure)
    }

    @Published private(set) var state: RunState = .idle
    @Published private(set) var isSupported: Bool = NFCNDEFReaderSession.readingAvailable
    @Published private(set) var featureEnabled: Bool = NFCCardProbeFeatureFlag.isEnabled()
    @Published var selectedMode: NFCCardProbeMode = .ndef

    private var session: NFCReaderSession?
    private var proxy: NFCBankCardProbeDelegateProxy?

    var isScanning: Bool {
        if case .scanning = state {
            return true
        }
        return false
    }

    var canStartScan: Bool {
        featureEnabled && !isScanning
    }

    func refreshEnvironment() {
        isSupported = NFCNDEFReaderSession.readingAvailable
        featureEnabled = NFCCardProbeFeatureFlag.isEnabled()
    }

    func setFeatureEnabled(_ isEnabled: Bool) {
        NFCCardProbeFeatureFlag.setEnabled(isEnabled)
        featureEnabled = isEnabled
        if !isEnabled {
            cancelScan()
            state = .idle
        }
    }

    func startScan() {
        refreshEnvironment()
        guard featureEnabled else {
            return
        }
        guard isSupported else {
            state = .failed(.unsupportedFeature)
            return
        }
        guard !isScanning else {
            return
        }

        let mode = selectedMode
        let proxy = NFCBankCardProbeDelegateProxy(model: self, mode: mode)
        self.proxy = proxy

        switch mode {
        case .ndef:
            let session = NFCNDEFReaderSession(
                delegate: proxy,
                queue: nil,
                invalidateAfterFirstRead: true
            )
            session.alertMessage = "请将卡片贴近 iPhone 顶部。本次诊断只读取 NDEF 记录类型与数量，不读取卡号、有效期或 CVV。"
            self.session = session
            state = .scanning(mode)
            session.begin()
        case .iso7816NonPayment:
            guard let session = NFCTagReaderSession(
                pollingOption: .iso14443,
                delegate: proxy,
                queue: nil
            ) else {
                self.session = nil
                self.proxy = nil
                state = .failed(.invalidSessionParameter)
                return
            }
            session.alertMessage = "请将卡片贴近 iPhone 顶部。本次诊断只用 Info.plist 中声明的非支付 AID 建立会话，不读取银行卡数据。"
            self.session = session
            state = .scanning(mode)
            session.begin()
        }
    }

    func cancelScan() {
        session?.invalidate()
        session = nil
        proxy = nil
        if isScanning {
            state = .idle
        }
    }

    func resetResult() {
        guard !isScanning else {
            return
        }
        state = .idle
    }

    fileprivate func receive(facts: NFCCardProbeTagFacts) {
        endSession()
        state = .finished(facts)
    }

    fileprivate func receive(failure: NFCCardProbeFailure) {
        if case .finished = state {
            // 结果已交付后系统仍可能回调一次 invalidation，直接忽略。
            endSession()
            return
        }
        endSession()
        if failure.isUserCancellation || failure.isInformationalCompletion {
            state = .idle
        } else {
            state = .failed(failure)
        }
    }

    private func endSession() {
        session?.invalidate()
        session = nil
        proxy = nil
    }
}

/// Core NFC 回调的隔离层：回调落在系统队列，结果统一切回主线程，并且只交付一次。
private final class NFCBankCardProbeDelegateProxy: NSObject, NFCNDEFReaderSessionDelegate, NFCTagReaderSessionDelegate, @unchecked Sendable {
    private weak var model: NFCBankCardProbeModel?
    private let mode: NFCCardProbeMode
    private let lock = NSLock()
    private var hasDeliveredResult = false

    init(model: NFCBankCardProbeModel, mode: NFCCardProbeMode) {
        self.model = model
        self.mode = mode
        super.init()
    }

    // MARK: - NFCNDEFReaderSessionDelegate

    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        deliver(invalidationError: error)
    }

    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        let records = messages.flatMap(\.records)
        let facts = NFCCardProbeTagFacts(
            family: .ndef,
            isAvailable: true,
            ndefRecordCount: records.count,
            ndefRecordTypeNames: records.map(Self.typeName(for:)),
            notes: ["只记录了 NDEF 记录类型与数量，未解析记录内容。"]
        )
        deliver(facts: facts)
    }

    // MARK: - NFCTagReaderSessionDelegate

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        deliver(invalidationError: error)
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard tags.count == 1, let tag = tags.first else {
            session.alertMessage = "检测到多张卡，请一次只贴一张卡片。"
            return
        }
        session.connect(to: tag) { [weak self] error in
            guard let self else {
                return
            }
            if let error {
                self.deliver(failure: NFCCardProbeFailure.from(rawErrorCode: (error as NSError).code))
                return
            }
            self.deliver(facts: Self.facts(for: tag))
        }
    }

    // MARK: - Result delivery

    private func deliver(facts: NFCCardProbeTagFacts) {
        guard claimResult() else {
            return
        }
        guard let model else {
            return
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                model.receive(facts: facts)
            }
        }
    }

    private func deliver(failure: NFCCardProbeFailure) {
        guard claimResult() else {
            return
        }
        guard let model else {
            return
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                model.receive(failure: failure)
            }
        }
    }

    private func deliver(invalidationError error: Error) {
        deliver(failure: NFCCardProbeFailure.from(rawErrorCode: (error as NSError).code))
    }

    private func claimResult() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if hasDeliveredResult {
            return false
        }
        hasDeliveredResult = true
        return true
    }

    // MARK: - Redacted tag facts

    private static func facts(for tag: NFCTag) -> NFCCardProbeTagFacts {
        switch tag {
        case .iso7816(let iso7816Tag):
            return NFCCardProbeTagFacts.iso7816(
                isAvailable: tag.isAvailable,
                initialSelectedAID: iso7816Tag.initialSelectedAID,
                notes: ["只读取了系统选中的 AID 与标签家族，未发送任何 APDU。"]
            )
        case .miFare:
            return NFCCardProbeTagFacts(
                family: .miFare,
                isAvailable: tag.isAvailable,
                notes: ["只读取了标签家族，未发送任何 MiFare 命令。"]
            )
        case .feliCa:
            return NFCCardProbeTagFacts(
                family: .feliCa,
                isAvailable: tag.isAvailable,
                notes: ["只读取了标签家族，未发送任何 FeliCa 命令。"]
            )
        case .iso15693:
            return NFCCardProbeTagFacts(
                family: .iso15693,
                isAvailable: tag.isAvailable,
                notes: ["只读取了标签家族，未发送任何 ISO15693 命令。"]
            )
        @unknown default:
            return NFCCardProbeTagFacts(
                family: .unknown,
                isAvailable: tag.isAvailable,
                notes: ["未知标签家族，未尝试任何读取。"]
            )
        }
    }

    private static func typeName(for record: NFCNDEFPayload) -> String {
        // iOS 27 SDK 对该 C 枚举的 Swift 前缀剥离不一致（如 NFCExternal），
        // 因此按 NFCTypeNameFormat 的原始值映射，避免依赖大小写敏感的名字。
        switch record.typeNameFormat.rawValue {
        case 0:
            return "空记录"
        case 1:
            return "NFC Forum 标准类型"
        case 2:
            return "media"
        case 3:
            return "绝对 URI"
        case 4:
            return "外部类型"
        case 5:
            return "未知类型"
        case 6:
            return "未变更"
        default:
            return "未知类型"
        }
    }
}

/// 设置页入口：NFC 银行卡诊断（技术验证，默认关闭）。
struct NFCBankCardProbeView: View {
    @StateObject private var model = NFCBankCardProbeModel()

    var body: some View {
        AndroidParityScreen {
            AndroidParitySection(title: "技术验证") {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.6)) {
                    Toggle(
                        "启用 NFC 诊断",
                        isOn: Binding(
                            get: { model.featureEnabled },
                            set: { model.setFeatureEnabled($0) }
                        )
                    )
                    .font(.headline.weight(.heavy))
                    .tint(AndroidParityPalette.primary)

                    Text("默认关闭。开启后才会启动一次性的只读诊断会话；关闭开关会立即结束当前会话。")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)

                    AndroidParityDivider()
                    AndroidParityInfoRow(
                        title: "设备支持",
                        value: model.isSupported ? "支持 NFC" : "当前设备不支持"
                    )
                    AndroidParityInfoRow(
                        title: "功能状态",
                        value: model.featureEnabled ? "已开启（仅本次诊断）" : "已关闭"
                    )
                }
            }

            AndroidParitySection(title: "诊断模式") {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.6)) {
                    Picker("诊断模式", selection: $model.selectedMode) {
                        ForEach(NFCCardProbeMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isScanning)

                    Text(model.selectedMode.subtitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)

                    Button {
                        model.startScan()
                    } label: {
                        Label("开始只读诊断", systemImage: "wave.3.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                    .disabled(!model.canStartScan)

                    if model.isScanning {
                        Button(role: .destructive) {
                            model.cancelScan()
                        } label: {
                            Label("结束会话", systemImage: "xmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .destructiveOutlined))
                    }
                }
            }

            resultSection
            boundarySection
        }
        .navigationTitle("NFC 银行卡诊断")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            model.refreshEnvironment()
            if !model.featureEnabled {
                model.resetResult()
            }
        }
        .onDisappear {
            model.cancelScan()
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        switch model.state {
        case .idle:
            AndroidParitySection(title: "诊断结果") {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.6)) {
                    Text("尚未运行诊断。")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
            }
        case .scanning(let mode):
            AndroidParitySection(title: "诊断结果") {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.6)) {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在以「\(mode.title)」模式等待贴卡……")
                            .font(.subheadline.weight(.semibold))
                    }
                    Text("系统会在 60 秒后自动结束会话。请勿同时贴多张卡。")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
            }
        case .finished(let facts):
            AndroidParitySection(title: "诊断结果") {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.6)) {
                    ForEach(Array(facts.summaryLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("以上信息均非敏感字段；未读取卡号、有效期、CVV、硬件 UID 或 APDU 原文。")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                    Button {
                        model.resetResult()
                    } label: {
                        Label("清除结果", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                }
            }
        case .failed(let failure):
            AndroidParitySection(title: "诊断失败") {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.6)) {
                    Text(failure.title)
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(AndroidParityPalette.primary)
                    Text(failure.message)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textPrimary)
                    if let recoverySuggestion = failure.recoverySuggestion {
                        Text(recoverySuggestion)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
                    AndroidParityInfoRow(title: "诊断码", value: failure.diagnosticCode)
                    Button {
                        model.resetResult()
                    } label: {
                        Label("重新开始", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                }
            }
        }
    }

    @ViewBuilder
    private var boundarySection: some View {
        AndroidParitySection(title: "数据边界") {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.6)) {
                Text(NFCCardProbePolicy.disclaimer)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                if NFCCardProbePolicy.readablePaymentCardFields.isEmpty {
                    AndroidParityInfoRow(title: "银行卡敏感字段", value: "普通 Core NFC 不可读")
                }
                AndroidParityInfoRow(
                    title: "已声明 AID",
                    value: NFCCardProbeAIDPolicy.declaredSelectIdentifiers.joined(separator: "、")
                )
            }
        }
    }
}
