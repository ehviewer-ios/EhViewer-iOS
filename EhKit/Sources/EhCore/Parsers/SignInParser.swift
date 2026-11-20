import Foundation

/// 论坛登录结果页。对应 Android `parser/SignInParser`
public enum SignInParser {
    static let namePattern = Regex2("<p>You are now logged in as: (.+?)<")
    static let errorPattern = Regex2(
        "(?:<h4>The error returned was:</h4>\\s*<p>(.+?)</p>)"
            + "|(?:<span class=\"postcolor\">(.+?)</span>)")

    /// 返回登录后的用户名；站点返回错误信息时抛 `EhError.server`，无法识别时抛 `EhError.parse`
    public static func parse(_ body: String) throws -> String {
        if let m = namePattern.firstMatch(in: body), let name = m[1] {
            return name
        }
        if let m = errorPattern.firstMatch(in: body) {
            throw EhError.server((m[1] ?? m[2]) ?? "")
        }
        throw EhError.parseFailure("Can't parse sign in", html: body)
    }
}
