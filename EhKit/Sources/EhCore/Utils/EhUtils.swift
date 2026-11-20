import Foundation

/// 对应 Android `client/EhUtils.kt` 中的纯逻辑部分（标题处理、缩略图分辨率、分类常量）。
/// 依赖 Settings / Cookie 的 `signOut` / `needSignedIn` 不在此处移植。
public enum EhUtils {
    /// 首页（不限分类），对应 `EhUtils.NONE`
    public static let NONE = -1
    /// 对应 `EhUtils.UNKNOWN`
    public static let UNKNOWN = 0x400
    /// 对应 `EhUtils.ALL_CATEGORY`（= UNKNOWN - 1 = 0x3ff）
    public static let ALL_CATEGORY = UNKNOWN - 1

    /// 去掉开头的 [XXX]、(XXX)、{XXX}、~XXX~ 以及空白
    public static let PATTERN_TITLE_PREFIX = Regex2(
        #"^(?:(?:\([^\)]*\))|(?:\[[^\]]*\])|(?:\{[^\}]*\})|(?:~[^~]*~)|\s+)*"#
    )

    /// 去掉结尾的 [XXX]、(XXX)、{XXX}、~XXX~ 以及类似 "ch. 1-23" 的章节号
    public static let PATTERN_TITLE_SUFFIX = Regex2(
        #"(?:\s+ch.[\s\d-]+)?(?:(?:\([^\)]*\))|(?:\[[^\]]*\])|(?:\{[^\}]*\})|(?:~[^~]*~)|\s+)*$"#,
        options: [.caseInsensitive]
    )

    /// 对应 `EhUtils.getCategory(String)`，返回位掩码整数
    public static func getCategory(_ type: String?) -> Int {
        EhCategory.from(string: type).rawValue
    }

    /// 对应 `EhUtils.getCategory(int)`，返回站点使用的小写分类名
    public static func getCategory(_ type: Int) -> String {
        EhCategory(rawValue: type).siteName
    }

    /// 对应 `EhUtils.getSuitableTitle`；`showJpnTitle` 对应 `Settings.getShowJpnTitle()`
    public static func getSuitableTitle(_ gi: GalleryInfo, showJpnTitle: Bool) -> String? {
        if showJpnTitle {
            return (gi.titleJpn?.isEmpty ?? true) ? gi.title : gi.titleJpn
        } else {
            return (gi.title?.isEmpty ?? true) ? gi.titleJpn : gi.title
        }
    }

    /// 对应 `EhUtils.judgeSuitableTitle`：日文标题 + 英文标题拼接后是否包含 key（Java 中 null 拼成 "null"）
    public static func judgeSuitableTitle(_ gi: GalleryInfo, key: String) -> Bool {
        let titleB = (gi.titleJpn ?? "null") + (gi.title ?? "null")
        return titleB.contains(key)
    }

    /// 对应 `EhUtils.extractTitle`：去掉标题前后的社团/作者/语言等括号信息，`|` 之后的英文翻译也去掉
    public static func extractTitle(_ title: String?) -> String? {
        guard var title else { return nil }
        title = replaceFirst(PATTERN_TITLE_PREFIX, in: title)
        title = replaceFirst(PATTERN_TITLE_SUFFIX, in: title)
        // 标题有时由罗马音和英文翻译以 '|' 拼接，只保留罗马音
        if let index = title.firstIndex(of: "|") {
            title = String(title[..<index])
        }
        return title.isEmpty ? nil : title
    }

    /// 对应 `EhUtils.handleThumbUrlResolution`。
    /// `resolution` 对应 `Settings.getThumbResolution()`：0 = 原样，1 = 250，2 = 300
    public static func handleThumbUrlResolution(_ url: String?, resolution: Int = 0) -> String? {
        guard let url else { return nil }
        let res: String
        switch resolution {
        case 1: res = "250"
        case 2: res = "300"
        default: return url
        }
        guard let i1 = url.lastIndex(of: "_"), let i2 = url.lastIndex(of: "."), i1 < i2 else {
            return url
        }
        return String(url[...i1]) + res + String(url[i2...])
    }

    // MARK: - URL 编解码（对应 java.net.URLEncoder / URLDecoder，UTF-8）

    private static let formUnreserved: Set<UInt8> = {
        var s = Set<UInt8>()
        for c in UInt8(ascii: "a")...UInt8(ascii: "z") { s.insert(c) }
        for c in UInt8(ascii: "A")...UInt8(ascii: "Z") { s.insert(c) }
        for c in UInt8(ascii: "0")...UInt8(ascii: "9") { s.insert(c) }
        for c in ".-*_".utf8 { s.insert(c) }
        return s
    }()

    /// 与 `URLEncoder.encode(s, "UTF-8")` 一致：空格 -> '+'，仅保留 `A-Za-z0-9.-*_`
    public static func urlEncode(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for b in s.utf8 {
            if formUnreserved.contains(b) {
                out.unicodeScalars.append(Unicode.Scalar(b))
            } else if b == UInt8(ascii: " ") {
                out.append("+")
            } else {
                out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    /// 与 `URLDecoder.decode(s, "UTF-8")` 一致：'+' -> 空格，%XX 解码。非法转义返回 nil（Java 抛 IllegalArgumentException）
    public static func urlDecode(_ s: String) -> String? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(s.utf8.count)
        var it = Array(s.utf8)[...]
        while let b = it.popFirst() {
            if b == UInt8(ascii: "+") {
                bytes.append(UInt8(ascii: " "))
            } else if b == UInt8(ascii: "%") {
                guard it.count >= 2,
                      let v = UInt8(String(decoding: it.prefix(2), as: UTF8.self), radix: 16) else { return nil }
                bytes.append(v)
                it = it.dropFirst(2)
            } else {
                bytes.append(b)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - 内部工具

    /// 对应 Java `Matcher.replaceFirst("")`
    static func replaceFirst(_ regex: Regex2, in s: String, with template: String = "") -> String {
        let ns = s as NSString
        guard let m = regex.re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return s }
        return ns.replacingCharacters(in: m.range, with: template)
    }
}
