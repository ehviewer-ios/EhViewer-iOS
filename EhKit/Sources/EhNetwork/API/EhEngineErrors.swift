import Foundation

/// 对应 Android `EhEngine.doThrowException`：请求或解析失败后，把错误统一转换为面向用户的 `EhError`。
///
/// Java 的顺序（仅在出现异常时执行；解析成功则不看状态码）：
/// 1. call 已取消 → CancelledException
/// 2. Sad Panda（Content-Disposition / Content-Type / Content-Length 三者匹配）→ "Sad Panda"
/// 3. body 含 kokomade 图片地址 → "今回はここまで" + 提示
/// 4. ParseException：body 不含 `<`（纯文本错误，如 api.php 的报错）→ 以 body 为消息；
///    body 为空 → "页面内容为空"；否则 → 解析失败（可选保存出错页面）
/// 5. EhException → 原样抛出
/// 6. HTTP 状态码 ≥ 400 → StatusCodeException
/// 7. 其他异常原样抛出
///
/// 与 `EhResponseValidator` 共用 Sad Panda / kokomade 常量；额外在第 3 步后识别 IP 封禁页（Java 由各解析器
/// 或第 4 步纯文本分支间接体现，这里统一为 `EhError.banned`）。
public enum EhEngineErrors {
    /// `R.string.kokomade_tip`
    public static let kokomadeTip = "设置->Eh->画廊站点->e-hentai"
    /// `R.string.error_empty_html`
    public static let emptyHtmlMessage = "页面内容为空"
    /// `R.string.error_igneous_wrong`
    public static let igneousWrongMessage = "错误的igneous\n检查账号里站权限后重新登录"

    /// - Parameters:
    ///   - error: 请求或解析抛出的错误
    ///   - response: 已收到的响应（传输层失败时为 nil）
    ///   - body: 已解码的响应文本（传输层失败时为 nil）
    ///   - onParseError: 解析失败回调（对应 `AppConfig.saveParseErrorBody`）
    public static func map(_ error: Error, response: EhHTTPResponse?, body: String?,
                           onParseError: (@Sendable (EhError, String) -> Void)? = nil) -> Error {
        if error is CancellationError || Task.isCancelled { return EhError.cancelled }
        if case EhError.cancelled = error { return error }

        if let h = response?.headers,
           h["Content-Disposition"] == EhResponseValidator.sadPandaDisposition,
           h["Content-Type"] == EhResponseValidator.sadPandaType,
           h["Content-Length"] == EhResponseValidator.sadPandaLength {
            return EhError.server("Sad Panda")
        }

        if let response, EhResponseValidator.isCloudflareChallenge(response) {
            return EhError.cloudflareChallenge(response.url.host ?? "站点")
        }

        if let body, body.contains(EhResponseValidator.kokomadeURL) {
            return EhError.server("今回はここまで\n\n" + kokomadeTip)
        }

        if let body, let msg = EhResponseValidator.banMessage(in: body) {
            return EhError.banned(msg)
        }

        if let e = error as? EhError, case let .parse(_, snippet) = e {
            if let body, !body.isEmpty, !body.contains("<") {
                return EhError.server(body)
            }
            if body?.isEmpty ?? true {
                return EhError.parse(emptyHtmlMessage, body: snippet)
            }
            onParseError?(e, body ?? "")
            return error
        }

        if error is EhError { return error }

        if let status = response?.status, status >= 400 {
            return EhError.http(status: status)
        }
        return EhResponseValidator.map(error)
    }

    /// 对应 `throwException(call, code, headers, body, null)`：无异常时只检查 Sad Panda / kokomade / 封禁 / 状态码。
    /// 用于不解析响应的写操作（addFavorites、downloadArchive）
    public static func check(_ response: EhHTTPResponse, body: String) throws {
        let h = response.headers
        if h["Content-Disposition"] == EhResponseValidator.sadPandaDisposition,
           h["Content-Type"] == EhResponseValidator.sadPandaType,
           h["Content-Length"] == EhResponseValidator.sadPandaLength {
            throw EhError.server("Sad Panda")
        }
        if body.contains(EhResponseValidator.kokomadeURL) {
            throw EhError.server("今回はここまで\n\n" + kokomadeTip)
        }
        if let msg = EhResponseValidator.banMessage(in: body) {
            throw EhError.banned(msg)
        }
        if response.status >= 400 {
            throw EhError.http(status: response.status)
        }
    }
}
