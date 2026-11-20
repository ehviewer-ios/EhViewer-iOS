import Foundation

/// Cookie 登录（不含 UI）。对应 Android `ui/scene/sign/CookieSignInScene` 中的校验、剪贴板解析与写入逻辑。
/// 写入后获取显示名用 `EhAPI.getProfileFromForums()`（对应 `GetProfileScene`）或 `EhAPI.getProfile()`。
public enum CookieSignIn {
    public struct Fields: Sendable, Hashable {
        public var memberId: String?
        public var passHash: String?
        public var igneous: String?
        public init(memberId: String? = nil, passHash: String? = nil, igneous: String? = nil) {
            self.memberId = memberId
            self.passHash = passHash
            self.igneous = igneous
        }
    }

    /// 对应 `checkIpbMemberId`：全为数字（空串也返回 true，与 Java 一致；为空由调用方先行判断）
    public static func checkIpbMemberId(_ id: String) -> Bool {
        id.unicodeScalars.allSatisfy { $0 >= "0" && $0 <= "9" }
    }

    /// 对应 `checkIpbPassHash`：32 位，仅 0-9 / a-z
    public static func checkIpbPassHash(_ hash: String) -> Bool {
        guard hash.unicodeScalars.count == 32 else { return false }
        return hash.unicodeScalars.allSatisfy { ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "z") }
    }

    /// 输入是否"看起来正确"。false 时 Android 弹出 `wrong_cookie_warning` 让用户确认后仍可写入
    public static func looksValid(memberId: String, passHash: String) -> Bool {
        checkIpbMemberId(memberId) && checkIpbPassHash(passHash)
    }

    /// 对应 `importCookie` + `handleCookie`：剪贴板文本按行解析 `name: value`（去掉所有空格，按 ":" 分割且必须恰为两段）。
    /// 行数 < 2 时返回 nil（`no_cookie_in_clipboard`）。无法识别的行被忽略。
    /// 与 Java 的差异：额外去掉行尾 `\r`（Windows 换行）
    public static func parseClipboard(_ text: String) -> Fields? {
        let rows = javaSplit(text, "\n")
        guard rows.count >= 2 else { return nil }
        var fields = Fields()
        for row in rows {
            var clean = row.replacingOccurrences(of: " ", with: "")
            if clean.hasSuffix("\r") { clean.removeLast() }
            let parts = javaSplit(clean, ":")
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case EhCookieStore.keyPassHash: fields.passHash = parts[1]
            case EhCookieStore.keyMemberId: fields.memberId = parts[1]
            case EhCookieStore.keyIgneous: fields.igneous = parts[1]
            default: break
            }
        }
        return fields
    }

    /// 对应 `storeCookie`：先登出，再为 e-hentai / exhentai / forums 写入永久 cookie（输入先 trim）
    public static func store(memberId: String, passHash: String, igneous: String?, in store: EhCookieStore) {
        let ws = CharacterSet.whitespacesAndNewlines
        store.setLoginCookies(memberId: memberId.trimmingCharacters(in: ws),
                              passHash: passHash.trimmingCharacters(in: ws),
                              igneous: igneous?.trimmingCharacters(in: ws))
    }

    /// Java `String.split`（字面分隔符）：去掉末尾空串
    /// 按 Unicode 标量切分，避免 "\r\n" 作为一个字符簇时无法按 "\n" 切开
    static func javaSplit(_ s: String, _ sep: Unicode.Scalar) -> [String] {
        var parts = s.unicodeScalars.split(separator: sep, omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) }
        while let last = parts.last, last.isEmpty { parts.removeLast() }
        if parts.isEmpty { return s.isEmpty ? [""] : [] }
        return parts
    }
}
