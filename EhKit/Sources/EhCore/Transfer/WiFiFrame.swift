import Foundation

/// WiFi 互传的一帧。对应 Android `client/wifi/WiFiFrame.java`。
///
/// 线上格式（大端，`DataOutputStream`），固定 22 字节头 + payload：
/// ```
/// 0  4  magic "EHBF"
/// 4  1  version = 1
/// 5  1  messageType   (u8)   WiFiDataHand.ERROR/RECEIVED/SEND
/// 6  2  dataType      (u16)  见 TransferDataType
/// 8  4  pageIndex     (i32)
/// 12 4  pageSize      (i32)
/// 16 2  flags         (u16)  bit0 = FLAG_LAST_CHUNK
/// 18 4  payloadLength (i32)
/// 22 …  payload
/// ```
public struct WiFiFrame: Sendable, Hashable {
    /// 写出时截断为低 8 位（Java `writeByte`），读入为无符号
    public var messageType: Int
    /// 写出时截断为低 16 位（Java `writeShort`），读入为无符号
    public var dataType: Int
    public var pageIndex: Int32
    public var pageSize: Int32
    /// 写出时截断为低 16 位，读入为无符号
    public var flags: Int
    public var payload: Data

    public init(messageType: Int, dataType: Int, pageIndex: Int32 = 0, pageSize: Int32 = 0, flags: Int = 0,
                payload: Data = Data()) {
        self.messageType = messageType
        self.dataType = dataType
        self.pageIndex = pageIndex
        self.pageSize = pageSize
        self.flags = flags
        self.payload = payload
    }
}

/// 帧解析错误（对应 Java 中抛出的 IOException）
public enum WiFiFrameError: Error, Sendable, Equatable {
    case invalidMagic
    case unsupportedVersion(Int)
    case invalidPayloadLength(Int)
    /// payload 超过解析器允许的上限（Android 无此限制，这里防止异常数据导致巨量分配）
    case payloadTooLarge(Int)
    /// 数据不完整
    case truncated
    /// 字符串超过 65535 字节（`writeString` 的 "String too long"）
    case stringTooLong
}

/// 帧编解码。对应 Android `client/wifi/WiFiFrameCodec.java`，字节级兼容。
public enum WiFiFrameCodec {
    public static let magic: [UInt8] = [0x45, 0x48, 0x42, 0x46]  // "EHBF"
    public static let version = 1
    public static let headerSize = 22
    public static let flagLastChunk = 1

    // MARK: - 帧头（writeFrame / readFrame）

    /// 对应 `writeFrame`：整帧字节
    public static func encode(_ frame: WiFiFrame) -> Data {
        var w = BigEndianWriter(capacity: headerSize + frame.payload.count)
        w.bytes(magic)
        w.u8(version)
        w.u8(frame.messageType)
        w.u16(frame.dataType)
        w.i32(frame.pageIndex)
        w.i32(frame.pageSize)
        w.u16(frame.flags)
        w.i32(Int32(truncatingIfNeeded: frame.payload.count))
        w.data.append(frame.payload)
        return w.data
    }

    /// 对应 `readFrame`：解析一段恰好包含完整一帧（或更多）的数据，返回第一帧
    public static func decode(_ data: Data) throws -> WiFiFrame {
        var parser = WiFiFrameParser()
        guard let frame = try parser.append(data).first else { throw WiFiFrameError.truncated }
        return frame
    }

    /// 解析帧头（前 22 字节）。返回帧（payload 为空）与 payload 长度
    static func parseHeader(_ h: UnsafeRawBufferPointer) throws -> (WiFiFrame, Int) {
        precondition(h.count >= headerSize)
        for i in 0..<4 where h[i] != magic[i] {
            throw WiFiFrameError.invalidMagic
        }
        var r = BigEndianReader(h)
        r.offset = 4
        let v = try r.u8()
        if v != version { throw WiFiFrameError.unsupportedVersion(v) }
        let messageType = try r.u8()
        let dataType = try r.u16()
        let pageIndex = try r.i32()
        let pageSize = try r.i32()
        let flags = try r.u16()
        let length = Int(try r.i32())
        if length < 0 { throw WiFiFrameError.invalidPayloadLength(length) }
        return (WiFiFrame(messageType: messageType, dataType: dataType, pageIndex: pageIndex,
                          pageSize: pageSize, flags: flags), length)
    }

    // MARK: - JSON 数据帧（encode / decodeDataHand）

    /// 对应 `encode(WiFiDataHand)`：payload 为 JSON，flags = 0，页码截断为 int
    public static func encode(_ hand: WiFiDataHand) -> WiFiFrame {
        WiFiFrame(messageType: hand.messageType, dataType: hand.dataType,
                  pageIndex: Int32(truncatingIfNeeded: hand.pageIndex),
                  pageSize: Int32(truncatingIfNeeded: hand.pageSize),
                  flags: 0, payload: hand.jsonData())
    }

    /// 对应 `decodeDataHand`：先取帧头字段，再用 JSON 中的 messageType/dataType/totalSize/part 覆盖。
    /// payload 为空或无法解析时返回 `messageType = ERROR` 的 hand（Android 解析失败会抛异常并断开）
    public static func decodeDataHand(_ frame: WiFiFrame) -> WiFiDataHand {
        guard !frame.payload.isEmpty, let json = try? TransferJSON.parse(frame.payload),
              case let .object(object) = json
        else {
            return WiFiDataHand(messageType: WiFiDataHand.error)
        }
        var hand = WiFiDataHand(messageType: frame.messageType, data: object["data"]?.objectValue)
        hand.dataType = frame.dataType
        hand.pageSize = Int64(frame.pageSize)
        hand.pageIndex = Int64(frame.pageIndex)
        if let v = object["messageType"] { hand.messageType = v.intValue }
        if let v = object["dataType"] { hand.dataType = v.intValue }
        if let v = object["totalSize"] { hand.pageSize = v.int64Value }
        if let v = object["part"] { hand.pageIndex = v.int64Value }
        return hand
    }

    // MARK: - 目录清单（encodeManifest / decodeManifest）

    /// 对应 `encodeManifest`：SEND / DOWNLOAD_DIR_MANIFEST。文件数超过 65535 时只写 65535 个计数（与 Java 一致：
    /// Java 计数截断但仍写出全部条目，这里同样写出全部条目以保持字节一致）
    public static func encodeManifest(gid: Int64, dirname: String, files: [WiFiDownloadMigration.FileMeta],
                                      pageIndex: Int32, pageSize: Int32) throws -> WiFiFrame {
        var w = BigEndianWriter()
        w.i64(gid)
        try w.string(dirname)
        w.u16(min(files.count, 65535))
        for meta in files {
            try w.string(meta.name)
            try w.string(meta.md5)
            w.i64(meta.size)
        }
        return WiFiFrame(messageType: WiFiDataHand.send, dataType: TransferDataType.downloadDirManifest,
                         pageIndex: pageIndex, pageSize: pageSize, flags: 0, payload: w.data)
    }

    /// 对应 `decodeManifest`，失败返回 nil
    public static func decodeManifest(_ frame: WiFiFrame) -> WiFiDownloadMigration.DirManifest? {
        frame.payload.withUnsafeBytes { raw -> WiFiDownloadMigration.DirManifest? in
            var r = BigEndianReader(raw)
            do {
                let gid = try r.i64()
                let dirname = try r.string()
                let count = try r.u16()
                var files: [WiFiDownloadMigration.FileMeta] = []
                files.reserveCapacity(count)
                for _ in 0..<count {
                    let name = try r.string()
                    let md5 = try r.string()
                    let size = try r.i64()
                    files.append(.init(name: name, md5: md5, size: size))
                }
                return .init(gid: gid, dirname: dirname, files: files,
                             pageIndex: frame.pageIndex, pageSize: frame.pageSize)
            } catch {
                return nil
            }
        }
    }

    // MARK: - 目录应答（encodeAck / decodeAck）

    /// 对应 `encodeAck`：RECEIVED / DOWNLOAD_DIR_ACK，页码 0
    public static func encodeAck(gid: Int64, dirname: String, filesNeeded: [String]) throws -> WiFiFrame {
        var w = BigEndianWriter()
        w.i64(gid)
        try w.string(dirname)
        w.u16(min(filesNeeded.count, 65535))
        for name in filesNeeded { try w.string(name) }
        return WiFiFrame(messageType: WiFiDataHand.received, dataType: TransferDataType.downloadDirAck,
                         pageIndex: 0, pageSize: 0, flags: 0, payload: w.data)
    }

    public static func decodeAck(_ frame: WiFiFrame) -> WiFiDownloadMigration.DirAck? {
        frame.payload.withUnsafeBytes { raw -> WiFiDownloadMigration.DirAck? in
            var r = BigEndianReader(raw)
            do {
                let gid = try r.i64()
                let dirname = try r.string()
                let count = try r.u16()
                var names: [String] = []
                names.reserveCapacity(count)
                for _ in 0..<count { names.append(try r.string()) }
                return .init(gid: gid, dirname: dirname, filesNeeded: names)
            } catch {
                return nil
            }
        }
    }

    // MARK: - 文件块（encodeFileChunk / decodeFileChunk）

    /// 对应 `encodeFileChunk`：SEND / DOWNLOAD_DIR_FILE，帧头 pageIndex = chunkIndex，pageSize = chunkTotal
    public static func encodeFileChunk(gid: Int64, name: String, fileMd5: String, chunkIndex: Int32,
                                       chunkTotal: Int32, data: Data, lastChunk: Bool) throws -> WiFiFrame {
        var w = BigEndianWriter(capacity: data.count + 64)
        w.i64(gid)
        try w.string(name)
        try w.string(fileMd5)
        w.i32(chunkIndex)
        w.i32(chunkTotal)
        w.i32(Int32(truncatingIfNeeded: data.count))
        w.data.append(data)
        return WiFiFrame(messageType: WiFiDataHand.send, dataType: TransferDataType.downloadDirFile,
                         pageIndex: chunkIndex, pageSize: chunkTotal,
                         flags: lastChunk ? flagLastChunk : 0, payload: w.data)
    }

    public static func decodeFileChunk(_ frame: WiFiFrame) -> WiFiDownloadMigration.FileChunk? {
        frame.payload.withUnsafeBytes { raw -> WiFiDownloadMigration.FileChunk? in
            var r = BigEndianReader(raw)
            do {
                let gid = try r.i64()
                let name = try r.string()
                let md5 = try r.string()
                let index = try r.i32()
                let total = try r.i32()
                let len = Int(try r.i32())
                if len < 0 { return nil }
                let data = try r.data(len)
                return .init(gid: gid, name: name, fileMd5: md5, chunkIndex: index, chunkTotal: total,
                             data: data, lastChunk: frame.flags & flagLastChunk != 0)
            } catch {
                return nil
            }
        }
    }
}

// MARK: - 增量解析（分包 / 粘包）

/// 从 TCP 字节流中增量解析帧。对应 `readFrame` 的阻塞读取，这里改为“喂数据、取出完整帧”。
///
/// ```swift
/// var parser = WiFiFrameParser()
/// for frame in try parser.append(chunk) { … }
/// ```
/// 出错（magic / version / 长度非法）后解析器不再可用，调用方应断开连接（与 Android 一致）。
public struct WiFiFrameParser: Sendable {
    /// 默认 payload 上限 64 MiB（文件块为 256 KiB，JSON 页很小）
    public static let defaultMaxPayloadLength = 64 << 20

    public let maxPayloadLength: Int
    private var buffer: [UInt8] = []
    private var readIndex = 0
    /// 已解析出帧头、等待 payload 的帧
    private var pending: (frame: WiFiFrame, length: Int)?

    public init(maxPayloadLength: Int = WiFiFrameParser.defaultMaxPayloadLength) {
        self.maxPayloadLength = maxPayloadLength
    }

    /// 缓冲中尚未消费的字节数
    public var bufferedByteCount: Int { buffer.count - readIndex }

    /// 追加数据，返回其中所有完整帧（按到达顺序）
    public mutating func append(_ data: Data) throws -> [WiFiFrame] {
        buffer.append(contentsOf: data)
        var frames: [WiFiFrame] = []
        while true {
            if pending == nil {
                guard bufferedByteCount >= WiFiFrameCodec.headerSize else { break }
                let parsed = try buffer.withUnsafeBytes { raw in
                    try WiFiFrameCodec.parseHeader(UnsafeRawBufferPointer(
                        rebasing: raw[readIndex..<(readIndex + WiFiFrameCodec.headerSize)]))
                }
                if parsed.1 > maxPayloadLength { throw WiFiFrameError.payloadTooLarge(parsed.1) }
                readIndex += WiFiFrameCodec.headerSize
                pending = parsed
            }
            guard let p = pending, bufferedByteCount >= p.length else { break }
            var frame = p.frame
            frame.payload = p.length == 0 ? Data() : Data(buffer[readIndex..<(readIndex + p.length)])
            readIndex += p.length
            pending = nil
            frames.append(frame)
        }
        compact()
        return frames
    }

    private mutating func compact() {
        if readIndex == buffer.count {
            buffer.removeAll(keepingCapacity: buffer.capacity <= 1 << 20)
            readIndex = 0
        } else if readIndex > 64 * 1024, readIndex * 2 > buffer.count {
            buffer.removeFirst(readIndex)
            readIndex = 0
        }
    }
}

// MARK: - 大端读写（Java DataOutputStream / DataInputStream）

struct BigEndianWriter {
    var data: Data

    init(capacity: Int = 64) {
        data = Data(capacity: capacity)
    }

    mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
    mutating func u8(_ v: Int) { data.append(UInt8(truncatingIfNeeded: v)) }
    mutating func u16(_ v: Int) {
        let x = UInt16(truncatingIfNeeded: v)
        data.append(UInt8(x >> 8)); data.append(UInt8(x & 0xFF))
    }

    mutating func i32(_ v: Int32) {
        let x = UInt32(bitPattern: v)
        for s in stride(from: 24, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: x >> UInt32(s))) }
    }

    mutating func i64(_ v: Int64) {
        let x = UInt64(bitPattern: v)
        for s in stride(from: 56, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: x >> UInt64(s))) }
    }

    /// 对应 `writeString`：u16 字节长度 + UTF-8
    mutating func string(_ s: String) throws {
        let utf8 = Array(s.utf8)
        if utf8.count > 65535 { throw WiFiFrameError.stringTooLong }
        u16(utf8.count)
        data.append(contentsOf: utf8)
    }
}

struct BigEndianReader {
    let p: UnsafeRawBufferPointer
    var offset = 0

    init(_ p: UnsafeRawBufferPointer) { self.p = p }

    private mutating func take(_ n: Int) throws -> UnsafeRawBufferPointer {
        guard n >= 0, offset + n <= p.count else { throw WiFiFrameError.truncated }
        defer { offset += n }
        return UnsafeRawBufferPointer(rebasing: p[offset..<(offset + n)])
    }

    mutating func u8() throws -> Int { Int(try take(1)[0]) }
    mutating func u16() throws -> Int {
        let b = try take(2)
        return Int(b[0]) << 8 | Int(b[1])
    }

    mutating func i32() throws -> Int32 {
        let b = try take(4)
        var x: UInt32 = 0
        for i in 0..<4 { x = x << 8 | UInt32(b[i]) }
        return Int32(bitPattern: x)
    }

    mutating func i64() throws -> Int64 {
        let b = try take(8)
        var x: UInt64 = 0
        for i in 0..<8 { x = x << 8 | UInt64(b[i]) }
        return Int64(bitPattern: x)
    }

    mutating func data(_ n: Int) throws -> Data { Data(try take(n)) }

    /// 对应 `readString`：非法 UTF-8 替换为 U+FFFD（与 Java `new String(bytes, UTF_8)` 一致）
    mutating func string() throws -> String {
        let n = try u16()
        return String(decoding: try take(n), as: UTF8.self)
    }
}
