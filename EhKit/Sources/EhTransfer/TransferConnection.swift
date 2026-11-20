#if canImport(Network)
import Foundation
import Network

/// 一条 TCP 连接上的帧收发。对应 Android `ConnectThread`（读循环 + 加锁发送）。
final class TransferConnection: @unchecked Sendable {
    let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var started = false

    init(_ connection: NWConnection) {
        self.connection = connection
        queue = DispatchQueue(label: "ehviewer.transfer.connection")
    }

    /// 对端地址描述
    var peerDescription: String {
        switch connection.endpoint {
        case let .hostPort(host, port): return "\(host):\(port)"
        default: return "\(connection.endpoint)"
        }
    }

    /// 启动并等待连接就绪
    func start() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.withLock { startContinuation = c }
                connection.stateUpdateHandler = { [weak self] state in
                    self?.handleState(state)
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private func handleState(_ state: NWConnection.State) {
        let c: CheckedContinuation<Void, Error>? = lock.withLock {
            switch state {
            case .ready, .failed, .cancelled:
                defer { startContinuation = nil }
                return startContinuation
            case .waiting:
                // 对端未监听等情况：Android 客户端会每 2 秒重试，这里交给调用方决定
                defer { startContinuation = nil }
                return startContinuation
            default:
                return nil
            }
        }
        guard let c else { return }
        switch state {
        case .ready: c.resume()
        case let .failed(e), let .waiting(e): c.resume(throwing: e)
        default: c.resume(throwing: TransferError.disconnected("cancelled"))
        }
        if case .waiting = state { connection.cancel() }
    }

    /// 发送一帧，等待系统接收（形成背压，避免文件块堆积在内存）
    func send(_ frame: WiFiFrame) async throws {
        let data = WiFiFrameCodec.encode(frame)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    /// 读循环：增量解析帧并逐帧交给 handler（handler 返回后再读下一段）。返回断开原因（正常关闭为 nil）
    func receiveLoop(_ handler: @escaping @Sendable (WiFiFrame) async -> Void) async -> String? {
        var parser = WiFiFrameParser()
        while true {
            do {
                guard let data = try await receiveChunk() else { return nil }
                if data.isEmpty { continue }
                for frame in try parser.append(data) {
                    await handler(frame)
                }
            } catch {
                return String(describing: error)
            }
        }
    }

    private func receiveChunk() async throws -> Data? {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                if let error {
                    c.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    c.resume(returning: data)
                } else if isComplete {
                    c.resume(returning: nil)
                } else {
                    c.resume(returning: Data())
                }
            }
        }
    }

    func cancel() {
        connection.cancel()
    }
}

/// 把一条连接接到会话引擎上
enum TransferConnectionDriver {
    /// 绑定引擎的发送端并报告已连接，返回连接代号
    static func attach(_ conn: TransferConnection, session: TransferSession,
                       emit: @escaping @Sendable (TransferEvent) -> Void) async -> Int {
        let generation = await session.engine.attach(sender: { [conn] frame in try await conn.send(frame) })
        emit(.connected(peer: conn.peerDescription))
        return generation
    }

    /// 运行读循环直到断开
    static func run(_ conn: TransferConnection, generation: Int, session: TransferSession) async {
        let engine = session.engine
        let reason = await conn.receiveLoop { frame in await engine.handle(frame) }
        conn.cancel()
        await engine.connectionClosed(generation: generation, reason: reason)
    }
}
#endif
