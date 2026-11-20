import Foundation
import MonicaSync
import Network

/// App 侧局域网同步传输层。
///
/// 设计约束（对应 issue #53）：
/// - 仅在前台、由用户显式操作时启动 Bonjour 广播或浏览，不做常驻后台广播；
/// - Bonjour/本地网络权限被拒绝时不崩溃，交给上层展示可操作的中文提示；
/// - 传输只负责搬运 `LanSyncFrame`，配对与加密全部复用 MonicaSync 的
///   `LanSyncHandshake` / `LanSyncSecureChannel`。
enum AppLanSyncNetworkError: Error, LocalizedError, Equatable {
    case connectionTimedOut
    case localNetworkDenied
    case connectionFailed(String)
    case disconnected(String)
    case frameStreamClosed

    var errorDescription: String? {
        switch self {
        case .connectionTimedOut:
            "连接对方设备超时。请确认两台设备在同一 Wi-Fi 或热点下，并保持本页面在前台。"
        case .localNetworkDenied:
            "Monica 没有「本地网络」权限，无法发现或连接附近的设备。请前往 设置 → 隐私与安全性 → 本地网络，为 Monica 打开权限后重试。"
        case .connectionFailed(let reason):
            "连接失败：\(reason)"
        case .disconnected(let reason):
            "连接已断开：\(reason)。已应用的条目不会重复导入，可以重新发起同步。"
        case .frameStreamClosed:
            "对方关闭了连接。"
        }
    }
}

/// 发现到的一台对端设备。`deviceID` 来自 Bonjour TXT 广播，仅用于展示和
/// 复用已配对记录；真正的身份校验在握手阶段用签名公钥完成。
struct AppLanSyncPeer: Identifiable, Equatable, @unchecked Sendable {
    let deviceID: String
    let displayName: String
    let endpoint: NWEndpoint

    var id: String {
        deviceID.isEmpty ? "\(displayName)-\(endpoint.hashValue)" : deviceID
    }
}

// MARK: - Listener

/// Bonjour 发布端。只在用户点「发起配对」期间存在。
final class AppLanSyncListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.monicapass.monica.lansync.listener")
    private let serviceName: String
    private let deviceID: String
    private let onReady: @Sendable (UInt16) -> Void
    private let onDenied: @Sendable () -> Void
    private let onFailed: @Sendable (String) -> Void
    private let onConnection: @Sendable (AppLanSyncConnection) -> Void
    private var listener: NWListener?

    init(
        serviceName: String,
        deviceID: String,
        onReady: @escaping @Sendable (UInt16) -> Void,
        onDenied: @escaping @Sendable () -> Void,
        onFailed: @escaping @Sendable (String) -> Void,
        onConnection: @escaping @Sendable (AppLanSyncConnection) -> Void
    ) {
        self.serviceName = serviceName
        self.deviceID = deviceID
        self.onReady = onReady
        self.onDenied = onDenied
        self.onFailed = onFailed
        self.onConnection = onConnection
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
            tcp.keepaliveInterval = 5
            tcp.keepaliveCount = 3
            tcp.connectionTimeout = 10
        }
        let listener = try NWListener(using: parameters, on: .any)
        listener.service = NWListener.Service(
            name: serviceName,
            type: LanSyncProtocolSpec.bonjourServiceType,
            domain: "local.",
            txtRecord: NWTXTRecord([
                "v": "\(LanSyncProtocolSpec.version)",
                "id": deviceID
            ])
        )
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady(self.listener?.port?.rawValue ?? 0)
            case .waiting(let error):
                if AppLanSyncNetwork.isLocalNetworkDenied(error) {
                    self.onDenied()
                }
            case .failed(let error):
                self.onFailed(error.localizedDescription)
            case .setup, .cancelled:
                break
            @unknown default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            let wrapped = AppLanSyncConnection(connection, onDenied: self.onDenied)
            self.onConnection(wrapped)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
        }
    }
}

// MARK: - Browser

/// Bonjour 浏览端。只在「加入配对」页面前台存在。
final class AppLanSyncBrowser: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.monicapass.monica.lansync.browser")
    private let onResults: @Sendable ([NWBrowser.Result]) -> Void
    private let onDenied: @Sendable () -> Void
    private let onFailed: @Sendable (String) -> Void
    private var browser: NWBrowser?

    init(
        onResults: @escaping @Sendable ([NWBrowser.Result]) -> Void,
        onDenied: @escaping @Sendable () -> Void,
        onFailed: @escaping @Sendable (String) -> Void
    ) {
        self.onResults = onResults
        self.onDenied = onDenied
        self.onFailed = onFailed
    }

    func start() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(
                type: LanSyncProtocolSpec.bonjourServiceType,
                domain: "local."
            ),
            using: parameters
        )
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready, .setup, .cancelled:
                break
            case .waiting(let error):
                if AppLanSyncNetwork.isLocalNetworkDenied(error) {
                    self.onDenied()
                }
            case .failed(let error):
                self.onFailed(error.localizedDescription)
            @unknown default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.onResults(Array(results))
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    func stop() {
        queue.async { [weak self] in
            self?.browser?.cancel()
            self?.browser = nil
        }
    }
}

// MARK: - Connection

/// 单条 TCP 连接的帧收发封装。帧格式与加密语义由 MonicaSync 定义。
final class AppLanSyncConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.monicapass.monica.lansync.connection")
    private let onDenied: @Sendable () -> Void
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var startResolved = false
    private var decoder = LanSyncFrameStreamDecoder()
    private var frameContinuation: AsyncThrowingStream<LanSyncFrame, Error>.Continuation?
    private var isReceiving = false
    private var isCancelled = false

    init(_ connection: NWConnection, onDenied: @escaping @Sendable () -> Void = {}) {
        self.connection = connection
        self.onDenied = onDenied
    }

    func start(timeout: TimeInterval = 15) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard !self.startResolved else {
                    continuation.resume(throwing: AppLanSyncNetworkError.connectionFailed("连接已结束"))
                    return
                }
                self.startContinuation = continuation
                self.connection.stateUpdateHandler = { [weak self] state in
                    self?.handleState(state)
                }
                self.connection.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self, !self.startResolved else { return }
                    self.resolveStart(.failure(AppLanSyncNetworkError.connectionTimedOut))
                }
            }
        }
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            resolveStart(.success(()))
        case .waiting(let error):
            if AppLanSyncNetwork.isLocalNetworkDenied(error, connection: connection) {
                onDenied()
                resolveStart(.failure(AppLanSyncNetworkError.localNetworkDenied))
            }
        case .failed(let error):
            resolveStart(.failure(AppLanSyncNetworkError.connectionFailed(error.localizedDescription)))
            finishFrames(throwing: AppLanSyncNetworkError.disconnected(error.localizedDescription))
        case .cancelled:
            resolveStart(.failure(AppLanSyncNetworkError.disconnected("连接已取消")))
            finishFrames(throwing: nil)
        case .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    private func resolveStart(_ result: Result<Void, Error>) {
        guard !startResolved else { return }
        startResolved = true
        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume(with: result)
    }

    /// 逐帧读取对端数据；同一连接只应调用一次。
    func frames() -> AsyncThrowingStream<LanSyncFrame, Error> {
        AsyncThrowingStream { continuation in
            queue.async {
                guard !self.isReceiving else {
                    continuation.finish(throwing: AppLanSyncNetworkError.connectionFailed("重复读取连接"))
                    return
                }
                self.isReceiving = true
                self.frameContinuation = continuation
                self.receiveNext()
            }
        }
    }

    private func receiveNext() {
        guard !isCancelled else {
            finishFrames(throwing: AppLanSyncNetworkError.frameStreamClosed)
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    let frames = try self.decoder.append(data)
                    for frame in frames {
                        self.frameContinuation?.yield(frame)
                    }
                } catch {
                    self.finishFrames(throwing: error)
                    return
                }
            }
            if let error {
                self.finishFrames(throwing: AppLanSyncNetworkError.disconnected(error.localizedDescription))
                return
            }
            if isComplete {
                if self.decoder.hasBufferedBytes {
                    self.finishFrames(throwing: AppLanSyncNetworkError.connectionFailed("收到的数据不完整"))
                } else {
                    self.finishFrames(throwing: nil)
                }
                return
            }
            self.receiveNext()
        }
    }

    private func finishFrames(throwing error: Error?) {
        guard let continuation = frameContinuation else { return }
        frameContinuation = nil
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    func send(_ frame: LanSyncFrame) async throws {
        let data: Data
        do {
            data = try LanSyncFrameCodec.encode(frame)
        } catch {
            throw AppLanSyncNetworkError.connectionFailed("无法编码同步帧")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: AppLanSyncNetworkError.disconnected(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self, !self.isCancelled else { return }
            self.isCancelled = true
            self.connection.cancel()
            self.finishFrames(throwing: nil)
        }
    }
}

// MARK: - Shared helpers

enum AppLanSyncNetwork {
    /// 本地网络权限被拒绝时，Network.framework 会把错误包在 `.waiting` 里。
    /// 常见形态：`.dns(kDNSServiceErr_PolicyDenied)`、`.posix(.EACCES)` 或
    /// 连接路径 `unsatisfiedReason == .localNetworkDenied`。
    static func isLocalNetworkDenied(_ error: NWError, connection: NWConnection? = nil) -> Bool {
        if case let .dns(code) = error, code == Int32(kDNSServiceErr_PolicyDenied) {
            return true
        }
        if case let .posix(code) = error, code == .EACCES {
            return true
        }
        if let reason = connection?.currentPath?.unsatisfiedReason, reason == .localNetworkDenied {
            return true
        }
        return false
    }

    static func makeConnection(to endpoint: NWEndpoint, onDenied: @escaping @Sendable () -> Void) -> AppLanSyncConnection {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
            tcp.keepaliveInterval = 5
            tcp.keepaliveCount = 3
            tcp.connectionTimeout = 10
        }
        return AppLanSyncConnection(NWConnection(to: endpoint, using: parameters), onDenied: onDenied)
    }

    /// 从 Bonjour 结果解析出展示用信息；TXT 里只有协议版本和只读 deviceID。
    static func peer(from result: NWBrowser.Result) -> AppLanSyncPeer? {
        var deviceID = ""
        if case let .bonjour(txt) = result.metadata {
            deviceID = txt["id"] ?? ""
        }
        var displayName = "附近设备"
        if case let .service(name: name, type: _, domain: _, interface: _) = result.endpoint {
            displayName = name
        }
        guard !displayName.isEmpty else { return nil }
        return AppLanSyncPeer(deviceID: deviceID, displayName: displayName, endpoint: result.endpoint)
    }
}
