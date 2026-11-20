#if canImport(Network)
import Foundation
import Network

/// WiFi 互传服务端（发送方）。对应 Android `WiFiServerActivity` + `ListenerThread`：
/// 监听 54321 端口，新连接到来时替换旧连接；连接后调用 `send(_:)` 发送数据。
///
/// 与 Android 互通：Android 接收端（WiFiClientActivity）连接的是“DHCP 网关:54321”，
/// 因此 iOS 需开启“个人热点”并让 Android 连上该热点（网关即 iOS，172.20.10.1）。
/// 同一 Wi-Fi 下 iOS ↔ iOS 可用二维码 / Bonjour 连接。
///
/// Info.plist 需要 `NSLocalNetworkUsageDescription`；启用 Bonjour 时还需在 `NSBonjourServices` 中声明 `_ehviewer._tcp`。
public final class TransferServer: @unchecked Sendable {
    public typealias ServerInfo = TransferServerInfo

    public let session: TransferSession
    public let port: UInt16
    /// Bonjour 服务名；nil 不发布
    public let bonjourName: String?
    /// 事件流（单消费者）
    public let events: AsyncStream<TransferEvent>

    private let continuation: AsyncStream<TransferEvent>.Continuation
    private let queue = DispatchQueue(label: "ehviewer.transfer.server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var current: TransferConnection?
    private var connectionTask: Task<Void, Never>?

    public init(session: TransferSession, port: UInt16 = TransferEndpoint.defaultPort, bonjourName: String? = nil) {
        self.session = session
        self.port = port
        self.bonjourName = bonjourName
        (events, continuation) = AsyncStream.makeStream(of: TransferEvent.self, bufferingPolicy: .bufferingNewest(256))
    }

    deinit {
        stop()
        continuation.finish()
    }

    /// 开始监听，返回本机地址 / 端口 / 二维码内容
    public func start() async throws -> ServerInfo {
        stop()
        let cont = continuation
        await session.engine.setEventHandler { cont.yield($0) }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true  // 对应 setReuseAddress(true)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw TransferError.invalidAddress("\(port)") }
        let listener = try NWListener(using: params, on: nwPort)
        if let bonjourName {
            listener.service = NWListener.Service(name: bonjourName, type: TransferEndpoint.bonjourType)
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        lock.withLock { self.listener = listener }

        let actualPort: UInt16 = try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    if once.fire() { c.resume(returning: listener?.port?.rawValue ?? 0) }
                case let .failed(e), let .waiting(e):
                    if once.fire() { c.resume(throwing: e) }
                    listener?.cancel()
                case .cancelled:
                    if once.fire() { c.resume(throwing: TransferError.disconnected("listener cancelled")) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        let info = ServerInfo(host: LocalNetwork.primaryIPv4(), port: actualPort, bonjourName: bonjourName)
        continuation.yield(.listening(info))
        return info
    }

    /// 对应 `DEVICE_CONNECTING`：关闭旧连接，启动新连接
    private func accept(_ conn: NWConnection) {
        let connection = TransferConnection(conn)
        let old: (TransferConnection?, Task<Void, Never>?) = lock.withLock {
            defer { current = connection }
            return (current, connectionTask)
        }
        old.0?.cancel()
        old.1?.cancel()
        let session = session
        let cont = continuation
        let task = Task {
            do {
                try await connection.start()
            } catch {
                cont.yield(.disconnected(reason: String(describing: error)))
                return
            }
            let generation = await TransferConnectionDriver.attach(connection, session: session,
                                                                   emit: { cont.yield($0) })
            await TransferConnectionDriver.run(connection, generation: generation, session: session)
        }
        lock.withLock { connectionTask = task }
    }

    /// 是否有已连接的对端
    public var isConnected: Bool {
        get async { await session.engine.isConnected }
    }

    /// 发送一种数据（需已连接）。对应“开始迁移”
    @discardableResult
    public func send(_ kind: TransferDataKind) async throws -> TransferSendSummary {
        try await session.send(kind)
    }

    /// 停止当前发送。对应“停止迁移”
    public func cancelSending() async {
        await session.cancelSending()
    }

    /// 停止监听并断开连接。对应 `onDestroy`
    public func stop() {
        let (l, c, t): (NWListener?, TransferConnection?, Task<Void, Never>?) = lock.withLock {
            defer { listener = nil; current = nil; connectionTask = nil }
            return (listener, current, connectionTask)
        }
        l?.cancel()
        c?.cancel()
        t?.cancel()
    }
}

/// 只触发一次的标志（用于 continuation 只 resume 一次）
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire() -> Bool {
        lock.withLock {
            if fired { return false }
            fired = true
            return true
        }
    }
}
#endif
