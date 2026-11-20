import Foundation

/// Cookie 模型。对应 OkHttp `okhttp3.Cookie`（字段与语义一致：expiresAt 为毫秒时间戳，非 persistent 为会话 cookie）
public struct EhCookie: Codable, Sendable, Hashable, CustomStringConvertible {
    /// OkHttp `HttpDate.MAX_DATE`：9999-12-31T23:59:59.999Z
    public static let maxDate: Int64 = 253_402_300_799_999

    public var name: String
    public var value: String
    /// 毫秒时间戳。会话 cookie 为 `maxDate`
    public var expiresAt: Int64
    /// 不带前导点、小写
    public var domain: String
    public var path: String
    public var secure: Bool
    public var httpOnly: Bool
    /// true：只匹配 domain 本身（Set-Cookie 未带 Domain 属性）
    public var hostOnly: Bool
    /// 是否持久化（带 Expires / Max-Age）
    public var persistent: Bool

    public init(
        name: String, value: String, domain: String, path: String = "/", expiresAt: Int64 = EhCookie.maxDate,
        persistent: Bool = false, secure: Bool = false, httpOnly: Bool = false, hostOnly: Bool = false
    ) {
        self.name = name
        self.value = value
        self.domain = Self.canonicalDomain(domain)
        self.path = path
        self.expiresAt = min(max(expiresAt, Int64.min), Self.maxDate)
        self.persistent = persistent
        self.secure = secure
        self.httpOnly = httpOnly
        self.hostOnly = hostOnly
    }

    /// 对应 `Cookie.Builder().expiresAt(Long.MAX_VALUE)`：永久且持久化
    public static func longLived(name: String, value: String, domain: String, path: String = "/",
                                 secure: Bool = false, httpOnly: Bool = false, hostOnly: Bool = false) -> EhCookie {
        EhCookie(name: name, value: value, domain: domain, path: path, expiresAt: maxDate, persistent: true,
                 secure: secure, httpOnly: httpOnly, hostOnly: hostOnly)
    }

    static func canonicalDomain(_ d: String) -> String {
        var s = d.lowercased()
        while s.hasPrefix(".") { s.removeFirst() }
        return s
    }

    public func isExpired(nowMillis: Int64) -> Bool { expiresAt <= nowMillis }

    /// 对应 `Cookie.matches(HttpUrl)`
    public func matches(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let domainOK = hostOnly ? host == domain : Self.domainMatch(host, domain)
        guard domainOK else { return false }
        guard Self.pathMatch(Self.encodedPath(url), path) else { return false }
        return !secure || url.scheme?.lowercased() == "https"
    }

    /// 对应 `Cookie.domainMatch(String, String)`
    public static func domainMatch(_ urlHost: String, _ domain: String) -> Bool {
        if urlHost == domain { return true }
        return urlHost.hasSuffix(domain)
            && urlHost.dropLast(domain.count).last == "."
            && !verifyAsIPAddress(urlHost)
    }

    /// 对应 `Cookie.pathMatch`
    public static func pathMatch(_ urlPath: String, _ path: String) -> Bool {
        if urlPath == path { return true }
        if urlPath.hasPrefix(path) {
            if path.hasSuffix("/") { return true }
            if urlPath.dropFirst(path.count).first == "/" { return true }
        }
        return false
    }

    /// OkHttp `verifyAsIpAddress` 的近似：纯数字点 或 含冒号的十六进制
    static func verifyAsIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return host.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." } }
        return !host.isEmpty && host.allSatisfy { $0.isNumber || $0 == "." }
    }

    static func encodedPath(_ url: URL) -> String {
        let p = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        return p.isEmpty ? "/" : p
    }

    /// Cookie 头片段
    public var pair: String { "\(name)=\(value)" }

    /// Set-Cookie 形式（对应 `Cookie.toString()`，用于同步给 WebView）
    public var description: String {
        var s = pair
        if persistent {
            if expiresAt == Int64.min {
                s += "; max-age=0"
            } else {
                s += "; expires=" + Self.httpDate(expiresAt)
            }
        }
        if !hostOnly { s += "; domain=" + domain }
        s += "; path=" + path
        if secure { s += "; secure" }
        if httpOnly { s += "; httponly" }
        return s
    }

    static func httpDate(_ millis: Int64) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(millis) / 1000))
    }
}

// MARK: - Set-Cookie 解析（对应 `Cookie.parse(long, HttpUrl, String)`）

extension EhCookie {
    /// 解析一条 Set-Cookie。返回 nil 表示非法或 domain 不匹配
    public static func parse(_ setCookie: String, url: URL, now: Date = Date()) -> EhCookie? {
        guard let urlHost = url.host?.lowercased() else { return nil }
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        let parts = setCookie.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard let pair = parts.first, let eq = pair.firstIndex(of: "=") else { return nil }
        let name = pair[..<eq].trimmingCharacters(in: .whitespaces)
        let value = pair[pair.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !hasControlOrNonASCII(name), !hasControlOrNonASCII(value) else { return nil }

        var expiresAt = maxDate
        var deltaSeconds: Int64 = -1
        var domain: String?
        var path: String?
        var secure = false, httpOnly = false, hostOnly = true, persistent = false

        for attr in parts.dropFirst() {
            let (an, av): (String, String)
            if let e = attr.firstIndex(of: "=") {
                an = attr[..<e].trimmingCharacters(in: .whitespaces)
                av = attr[attr.index(after: e)...].trimmingCharacters(in: .whitespaces)
            } else {
                an = attr.trimmingCharacters(in: .whitespaces)
                av = ""
            }
            switch an.lowercased() {
            case "expires":
                if let t = parseExpires(av) {
                    expiresAt = t
                    persistent = true
                }
            case "max-age":
                if let d = parseMaxAge(av) {
                    deltaSeconds = d
                    persistent = true
                }
            case "domain":
                if !av.hasSuffix("."), !av.isEmpty {
                    let d = canonicalDomain(av)
                    if !d.isEmpty {
                        domain = d
                        hostOnly = false
                    }
                }
            case "path": path = av
            case "secure": secure = true
            case "httponly": httpOnly = true
            default: break
            }
        }

        if deltaSeconds == Int64.min {
            expiresAt = Int64.min
        } else if deltaSeconds != -1 {
            let deltaMillis = deltaSeconds <= Int64.max / 1000 ? deltaSeconds * 1000 : Int64.max
            let (sum, overflow) = nowMillis.addingReportingOverflow(deltaMillis)
            expiresAt = overflow || sum < nowMillis || sum > maxDate ? maxDate : sum
        }

        let finalDomain: String
        if let domain {
            guard domainMatch(urlHost, domain) else { return nil }
            // 公共后缀近似校验：拒绝顶级域（如 "org"）
            if urlHost.count != domain.count, !domain.contains(".") { return nil }
            finalDomain = domain
        } else {
            finalDomain = urlHost
        }

        var finalPath: String
        if let path, path.hasPrefix("/") {
            finalPath = path
        } else {
            let ep = encodedPath(url)
            if let slash = ep.lastIndex(of: "/"), slash != ep.startIndex {
                finalPath = String(ep[..<slash])
            } else {
                finalPath = "/"
            }
        }
        if finalPath.isEmpty { finalPath = "/" }

        var c = EhCookie(name: name, value: value, domain: finalDomain, path: finalPath, persistent: persistent,
                         secure: secure, httpOnly: httpOnly, hostOnly: hostOnly)
        c.expiresAt = expiresAt
        return c
    }

    static func hasControlOrNonASCII(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value <= 0x1f || $0.value >= 0x7f }
    }

    /// 对应 `Cookie.parseMaxAge`：≤0 表示立即过期（Long.MIN_VALUE）
    static func parseMaxAge(_ s: String) -> Int64? {
        if let v = Int64(s) { return v <= 0 ? Int64.min : v }
        let digits = s.hasPrefix("-") ? s.dropFirst() : Substring(s)
        if !digits.isEmpty, digits.allSatisfy(\.isNumber) { return s.hasPrefix("-") ? Int64.min : Int64.max }
        return nil
    }

    /// RFC 6265 §5.1.1 宽松日期解析（对应 `Cookie.parseExpires`）。返回毫秒
    static func parseExpires(_ s: String) -> Int64? {
        func isDelimiter(_ c: UInt8) -> Bool {
            !(c < 0x20 && c != 0x09) && !(c >= 0x30 && c <= 0x39) && !(c >= 0x41 && c <= 0x5A) && !(c >= 0x61 && c <= 0x7A) && c != 0x3A
        }
        var tokens: [String] = []
        var cur = ""
        for c in s.utf8 {
            if isDelimiter(c) || c == 0x09 {
                if !cur.isEmpty { tokens.append(cur); cur = "" }
            } else {
                cur.append(Character(UnicodeScalar(c)))
            }
        }
        if !cur.isEmpty { tokens.append(cur) }

        var hour = -1, minute = -1, second = -1, day = -1, month = -1, year = -1
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        for t in tokens {
            if hour == -1 {
                let hms = t.split(separator: ":")
                if hms.count == 3, hms.allSatisfy({ (1...2).contains($0.count) && $0.allSatisfy(\.isNumber) }),
                   let h = Int(hms[0]), let m = Int(hms[1]), let sec = Int(hms[2].prefix(2)) {
                    hour = h; minute = m; second = sec
                    continue
                }
            }
            // 形如 (\d{n})[^\d]*：前导数字个数在范围内且其后不再有数字
            let lead = t.prefix(while: { $0.isASCII && $0.isNumber })
            let restHasDigit = t.dropFirst(lead.count).contains { $0.isNumber }
            if day == -1, (1...2).contains(lead.count), !restHasDigit, let d = Int(lead) {
                day = d
                continue
            }
            if month == -1, t.count >= 3, let mi = months.firstIndex(of: String(t.prefix(3)).lowercased()) {
                month = mi + 1
                continue
            }
            if year == -1, (2...4).contains(lead.count), !restHasDigit, let y = Int(lead) {
                year = y
                continue
            }
        }
        if (70...99).contains(year) { year += 1900 }
        if (0...69).contains(year) { year += 2000 }
        guard year >= 1601, (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = second
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let date = cal.date(from: comps) else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }
}

/// URLSession 会把多个 Set-Cookie 用逗号合并成一个头。按「逗号后紧跟 name=」切回多条，
/// 并避开 `Expires=Wed, 21 Oct 2015 ...` 中的逗号
public enum SetCookieSplitter {
    public static func split(_ joined: String) -> [String] {
        var result: [String] = []
        var current = ""
        let chars = Array(joined)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == ",", startsNewCookie(chars, from: i + 1) {
                let t = current.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { result.append(t) }
                current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        let t = current.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { result.append(t) }
        return result
    }

    /// 从 idx 起（跳过空白）是否为 `token=`，token 不含空白、';'、','
    private static func startsNewCookie(_ chars: [Character], from idx: Int) -> Bool {
        var j = idx
        while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
        let start = j
        while j < chars.count {
            let c = chars[j]
            if c == "=" { return j > start }
            if c == ";" || c == "," || c == " " || c == "\t" { return false }
            j += 1
        }
        return false
    }
}
