#if canImport(Network)
import Foundation
import Network

/// WiFi 互传客户端（接收方）。对应 Android `WiFiClientActivity`：连接服务端后，按协议接收数据并写入数据库 /
/// 下载目录，进度通过 `events` 报告。客户端也可以调用 `send(_:)` 向 iOS 服务端反向发送（Android 服务端不接收）。
///
/// 连接 Android 发送端：Android 开热点，iOS 连上该热点后调用 `connectToGateway()`
/// （Android 接收端的做法是连接 DHCP 网关；iOS 无法读取 DHCP 网关，用网段第一个地址近似，失败时请手动输入地址）。
public final class TransferClient: @unchecked Sendable {
    public let session: TransferSession
    /// 事件流（单消费者）
    public let events: AsyncStream<TransferEvent>

    private let continuation: AsyncStream<TransferEvent>.Continuation
    private let lock = NSLock()
    private var current: TransferConnection?
    private var connectionTask: Task<Void, Never>?

    public init(session: TransferSession) {
        self.session = session
        (events, continuation) = AsyncStream.makeStream(of: TransferEvent.self, bufferingPolicy: .bufferingNewest(256))
    }

    deinit {
        disconnect()
        continuation.finish()
    }

    /// 解析二维码 / 手输地址后连接（格式见 `TransferEndpoint.parse`）
    public func connect(qrString: String) async throws {
        guard let (host, port) = TransferEndpoint.parse(qrString) else {
            throw TransferError.invalidAddress(qrString)
        }
        try await connect(host: host, port: port)
    }

    /// 连接 host:port（默认 54321）
    public func connect(host: String, port: UInt16 = TransferEndpoint.defaultPort) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw TransferError.invalidAddress("\(host):\(port)") }
        try await connect(endpoint: .hostPort(host: NWEndpoint.Host(host), port: nwPort))
    }

    /// 连接到当前 Wi-Fi 网关（Android 热点发送端）。对应 `getWifiRouteIPAddress` + `new Socket(route, PORT)`
    public func connectToGateway(port: UInt16 = TransferEndpoint.defaultPort) async throws {
        guard let gw = LocalNetwork.gatewayGuess() else { throw TransferError.invalidAddress("gateway") }
        try await connect(host: gw, port: port)
    }

    /// 连接任意端点（如 Bonjour 浏览得到的 `.service(name:type:domain:interface:)`）
    public func connect(endpoint: NWEndpoint) async throws {
        disconnect()
        let cont = continuation
        await session.engine.setEventHandler { cont.yield($0) }
        let connection = TransferConnection(NWConnection(to: endpoint, using: .tcp))
        try await connection.start()
        let session = session
        let generation = await TransferConnectionDriver.attach(connection, session: session, emit: { cont.yield($0) })
        let task = Task {
            await TransferConnectionDriver.run(connection, generation: generation, session: session)
        }
        lock.withLock {
            current = connection
            connectionTask = task
        }
    }

    public var isConnected: Bool {
        get async { await session.engine.isConnected }
    }

    /// 向对端发送一种数据（对端需为 iOS；Android 服务端会忽略 SEND 帧）
    @discardableResult
    public func send(_ kind: TransferDataKind) async throws -> TransferSendSummary {
        try await session.send(kind)
    }

    public func cancelSending() async {
        await session.cancelSending()
    }

    /// 断开连接。对应 `onDestroy` / `closeConnect`
    public func disconnect() {
        let (c, t): (TransferConnection?, Task<Void, Never>?) = lock.withLock {
            defer { current = nil; connectionTask = nil }
            return (current, connectionTask)
        }
        c?.cancel()
        t?.cancel()
    }
}
#endif
