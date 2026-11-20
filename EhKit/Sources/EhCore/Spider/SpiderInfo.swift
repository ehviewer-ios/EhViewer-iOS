import Foundation

/// 下载目录 / 阅读缓存中的 `.ehviewer` 文件。对应 Android `spider/SpiderInfo.java`。
///
/// 支持两种格式：
/// - 文本 v1 / v2（本 Android 分支写出的格式，iOS 也写这个格式，保证可被 Android 读回）
/// - CBOR map（上游 / 新版 Android 写出），只读；见 `CborSpiderHeader.kt`
///
/// 文本 v2 布局（每行以 `\n` 结尾）：
/// ```
/// VERSION2
/// %08x        startPage（十六进制）
/// gid
/// token
/// 1           mode（历史字段，Android 读时忽略、写时固定 "1"）
/// previewPages
/// previewPerPage
/// pages
/// {index} {pToken}   × N（跳过 "failed" 和空值）
/// ```
/// v1 没有 VERSION 行；第 7 行同样会被读出但不解析为 previewPerPage。
public struct SpiderInfo: Sendable, Hashable, Codable {
    public static let versionString = "VERSION"
    public static let version = 2
    /// 本地文件页数上限，防止损坏文件导致巨量分配
    public static let maxPages = 100_000
    static let maxHeaderLine = 8192
    static let maxPTokenLine = 2048
    static let maxStoredPTokenChars = 1024
    /// CBOR 头读取时 token 的最大字节数（与 Android 一致）
    static let maxCborTokenChars = 128
    public static let tokenFailed = "failed"

    /// 文件格式
    public enum Format: Sendable, Hashable {
        case text(version: Int)
        case cbor
    }

    public var startPage: Int = 0
    public var gid: Int64 = -1
    public var token: String?
    public var pages: Int = -1
    public var previewPages: Int = -1
    public var previewPerPage: Int = -1
    /// 页序号（0 起）→ pToken
    public var pTokenMap: [Int: String] = [:]
    /// 文本格式第 5 行（Android 中恒为 1，读取时忽略）
    public var mode: Int = 1

    public init(
        startPage: Int = 0, gid: Int64 = -1, token: String? = nil, pages: Int = -1,
        previewPages: Int = -1, previewPerPage: Int = -1, pTokenMap: [Int: String] = [:]
    ) {
        self.startPage = startPage; self.gid = gid; self.token = token; self.pages = pages
        self.previewPages = previewPages; self.previewPerPage = previewPerPage; self.pTokenMap = pTokenMap
    }

    // MARK: - 读取入口（自动识别格式）

    /// 判断数据格式：首字节主类型为 5（map）视为 CBOR，否则视为文本
    public static func detectFormat(_ data: Data) -> Format? {
        guard let first = data.first else { return nil }
        if first >> 5 == 5 { return .cbor }
        return .text(version: 0)
    }

    /// 读取 `.ehviewer`，自动识别文本 / CBOR。失败返回 nil。
    /// - Parameter includePTokens: false 时只读头部（对应 Android `readHeader`），pTokenMap 为空，不应写回磁盘
    public static func read(_ data: Data, includePTokens: Bool = true) -> SpiderInfo? {
        switch detectFormat(data) {
        case .cbor: return readCbor(data, includePTokens: includePTokens)
        case .text: return readText(data, includePTokens: includePTokens)
        case nil: return nil
        }
    }

    public static func readHeader(_ data: Data) -> SpiderInfo? {
        read(data, includePTokens: false)
    }

    public static func read(contentsOf url: URL, includePTokens: Bool = true) -> SpiderInfo? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return read(data, includePTokens: includePTokens)
    }

    // MARK: - 文本格式

    /// 文本 v1/v2 读取。逐字节对照 Android `parseHeader` / `readPTokens`
    public static func readText(_ data: Data, includePTokens: Bool = true) -> SpiderInfo? {
        var reader = AsciiLineReader(bytes: [UInt8](data))
        do {
            guard var info = try parseHeader(&reader) else { return nil }
            if includePTokens {
                try readPTokens(&reader, into: &info)
            }
            guard info.gid != -1, info.token != nil, info.pages != -1 else { return nil }
            return info
        } catch {
            return nil
        }
    }

    private static func parseHeader(_ r: inout AsciiLineReader) throws -> SpiderInfo? {
        var info = SpiderInfo()
        var line: String? = try r.readLine(max: maxHeaderLine)
        let version = getVersion(line)
        if version == Self.version {
            line = try r.readLine(max: maxHeaderLine)
        } else if version == 1 {
            // pass
        } else {
            return nil
        }
        info.startPage = getStartPage(line)
        info.gid = try parseLong(try r.readLine(max: maxHeaderLine))
        info.token = try r.readLine(max: maxHeaderLine)
        let modeLine = try r.readLine(max: maxHeaderLine)
        info.mode = Int(modeLine) ?? 1
        info.previewPages = try parseInt(try r.readLine(max: maxHeaderLine))
        line = try r.readLine(max: maxHeaderLine)
        if version != 1 {
            info.previewPerPage = try parseInt(line ?? "")
        }
        info.pages = try parseInt(try r.readLine(max: maxHeaderLine))
        if info.pages <= 0 || info.pages > maxPages {
            return nil
        }
        return info
    }

    private static func readPTokens(_ r: inout AsciiLineReader, into info: inout SpiderInfo) throws {
        info.pTokenMap = [:]
        var linesRead = 0
        while linesRead < info.pages {
            let line: String
            do {
                line = try r.readLine(max: maxPTokenLine)
            } catch AsciiLineReader.ReadError.eof {
                break
            }
            if let (index, pToken) = tryParsePTokenLine(line) {
                info.pTokenMap[index] = pToken
            }
            linesRead += 1
        }
    }

    /// 解析一行 "{index} {pToken}"；格式不对或 index 损坏时返回 nil（跳过该行）
    public static func tryParsePTokenLine(_ line: String) -> (index: Int, pToken: String)? {
        guard let space = line.firstIndex(of: " "), space != line.startIndex else { return nil }
        guard let index = try? parseInt(String(line[..<space])) else { return nil }
        let pToken = String(line[line.index(after: space)...])
        if pToken.isEmpty || pToken.utf16.count > maxStoredPTokenChars { return nil }
        return (index, pToken)
    }

    /// 对应 `getStartPage`：逐字符按十六进制累加，非 hex 字符只乘 16 不加（与 Java 一致，int 溢出回绕）
    static func getStartPage(_ str: String?) -> Int {
        guard let str else { return 0 }
        var startPage: Int32 = 0
        for ch in str.utf16 {
            startPage = startPage &* 16
            if ch >= 0x30, ch <= 0x39 {
                startPage = startPage &+ Int32(ch - 0x30)
            } else if ch >= 0x61, ch <= 0x66 {
                startPage = startPage &+ Int32(ch - 0x61 + 10)
            }
        }
        return Int(max(startPage, 0))
    }

    static func getVersion(_ str: String?) -> Int {
        guard let str else { return -1 }
        if str.hasPrefix(versionString) {
            return Int32(str.dropFirst(versionString.count)).map(Int.init) ?? -1
        }
        return 1
    }

    /// Java `Integer.parseInt`：严格十进制，允许前导 +/-，32 位范围
    static func parseInt(_ s: String) throws -> Int {
        guard let v = Int32(s) else { throw AsciiLineReader.ReadError.number }
        return Int(v)
    }

    /// Java `Long.parseLong`
    static func parseLong(_ s: String) throws -> Int64 {
        guard let v = Int64(s) else { throw AsciiLineReader.ReadError.number }
        return v
    }

    /// 写出文本 v2。对应 Android `write(OutputStream)`
    public func textData() -> Data {
        var s = "\(Self.versionString)\(Self.version)\n"
        s += String(format: "%08x", UInt32(truncatingIfNeeded: max(startPage, 0))) + "\n"
        s += "\(gid)\n"
        s += "\(token ?? "null")\n"
        s += "1\n"
        s += "\(previewPages)\n"
        s += "\(previewPerPage)\n"
        s += "\(pages)\n"
        for key in pTokenMap.keys.sorted() {
            guard let value = pTokenMap[key], !value.isEmpty, value != Self.tokenFailed else { continue }
            s += "\(key) \(value)\n"
        }
        return Data(s.utf8)
    }

    public func write(to url: URL) throws {
        try textData().write(to: url, options: .atomic)
    }

    /// 对应 `updateSpiderInfo`（不覆盖 startPage）
    public mutating func update(from newInfo: SpiderInfo) {
        pages = newInfo.pages
        gid = newInfo.gid
        token = newInfo.token
        pTokenMap = newInfo.pTokenMap
        previewPerPage = newInfo.previewPerPage
        previewPages = newInfo.previewPages
    }

    // MARK: - CBOR 格式

    /// 读取 CBOR map 形式的 `.ehviewer`。读出全部已知字段：
    /// `gid`、`token`、`pages`、`startPage`、`previewPages`、`previewPerPage`、`pTokenMap`（int → text）。
    /// 未知字段跳过。与 Android 一致：gid/token 已读到后，后续字段损坏仍返回已读内容。
    /// gid < 0 或 token 为空时返回 nil。
    public static func readCbor(_ data: Data, includePTokens: Bool = true) -> SpiderInfo? {
        var reader = CBORReader(data)
        var info = SpiderInfo()
        var token: String?
        do {
            let count = try reader.readMapHeader()
            var index = 0
            while count.map({ index < $0 }) ?? true {
                if count == nil, try reader.peekBreak() {
                    try reader.consumeBreak()
                    break
                }
                let keyValue = try reader.readValue()
                let key = keyValue.stringValue.flatMap { $0.utf8.count <= 64 ? $0 : nil }
                if key == "pTokenMap", !includePTokens {
                    try reader.skipValue()
                    index += 1
                    continue
                }
                let value = try reader.readValue()
                switch key {
                case "gid":
                    if let v = value.int64Value { info.gid = v }
                case "token":
                    if let v = value.stringValue, !v.isEmpty, v.utf8.count <= maxCborTokenChars { token = v }
                case "pages":
                    if let v = value.intValue { info.pages = v }
                case "startPage":
                    if let v = value.intValue { info.startPage = max(v, 0) }
                case "previewPages":
                    if let v = value.intValue { info.previewPages = v }
                case "previewPerPage":
                    if let v = value.intValue { info.previewPerPage = v }
                case "pTokenMap":
                    info.pTokenMap = parseCborPTokenMap(value)
                default:
                    break
                }
                index += 1
            }
        } catch {
            // 与 Android 一致：gid、token 在 pTokenMap 之前，后续损坏时保留已读字段
        }
        guard info.gid >= 0, let token, !token.isEmpty else { return nil }
        info.token = token
        return info
    }

    private static func parseCborPTokenMap(_ value: CBORValue) -> [Int: String] {
        var map: [Int: String] = [:]
        switch value {
        case let .map(entries):
            for e in entries {
                let k = e.key.intValue ?? e.key.stringValue.flatMap { Int($0) }
                guard let k, let v = e.value.stringValue, !v.isEmpty,
                      v.utf16.count <= maxStoredPTokenChars else { continue }
                map[k] = v
            }
        case let .array(items):
            // 兜底：数组形式按下标存储
            for (i, item) in items.enumerated() {
                if let v = item.stringValue, !v.isEmpty { map[i] = v }
            }
        default:
            break
        }
        return map
    }
}

/// 对应 `IOUtils.readAsciiLine`：按字节读到 `\n`，去掉末尾 `\r`，字节按 Latin-1 转字符。
/// 未遇到 `\n` 就到达末尾时抛 EOF（即最后一行若无换行会被丢弃，与 Java 行为一致）。
struct AsciiLineReader {
    enum ReadError: Error { case eof, lineTooLong, number }

    let bytes: [UInt8]
    var offset = 0

    mutating func readLine(max maxLength: Int) throws -> String {
        var buf: [UInt8] = []
        while true {
            guard offset < bytes.count else { throw ReadError.eof }
            let c = bytes[offset]
            offset += 1
            if c == 0x0A { break }
            if buf.count >= maxLength { throw ReadError.lineTooLong }
            buf.append(c)
        }
        if buf.last == 0x0D { buf.removeLast() }
        return String(buf.map { Character(Unicode.Scalar($0)) })
    }
}
