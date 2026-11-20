import Foundation

/// 通用响应错误识别。对应 Android `EhEngine.doThrowException` 中与业务无关的部分 + 封禁页识别
public enum EhResponseValidator {
    static let sadPandaDisposition = "inline; filename=\"sadpanda.jpg\""
    static let sadPandaType = "image/gif"
    static let sadPandaLength = "9615"
    static let kokomadeURL = "https://exhentai.org/img/kokomade.jpg"
    static let banMarker = "Your IP address has been temporarily banned"

    /// 依次检查：Sad Panda → 今回はここまで → IP 封禁 → HTTP 状态码（≥400）
    public static func validate(_ response: EhHTTPResponse) throws {
        let h = response.headers
        if h["Content-Disposition"] == sadPandaDisposition, h["Content-Type"] == sadPandaType,
           h["Content-Length"] == sadPandaLength {
            throw EhError.server("Sad Panda")
        }
        if isCloudflareChallenge(response) {
            throw EhError.cloudflareChallenge(response.url.host ?? "站点")
        }
        if isTextual(response) {
            let text = response.text
            if text.contains(kokomadeURL) {
                throw EhError.server("今回はここまで")
            }
            if let msg = banMessage(in: text) {
                throw EhError.banned(msg)
            }
        }
        if response.status >= 400 {
            throw EhError.http(status: response.status)
        }
    }

    /// Cloudflare 托管质询（"Just a moment..."）页：403/503 + `cf-mitigated: challenge` 或页面特征
    public static func isCloudflareChallenge(_ r: EhHTTPResponse) -> Bool {
        guard r.status == 403 || r.status == 503 || r.status == 429 else { return false }
        if r.headers["cf-mitigated"]?.lowercased() == "challenge" { return true }
        guard isTextual(r) else { return false }
        let text = r.text
        return text.contains("_cf_chl_opt") || text.contains("<title>Just a moment...</title>")
    }

    static func isTextual(_ r: EhHTTPResponse) -> Bool {
        guard let ct = r.contentType?.lowercased() else { return r.body.count < 1 << 20 }
        return ct.hasPrefix("text/") || ct.contains("json") || ct.contains("html") || ct.contains("xml")
    }

    /// 提取封禁提示（去 HTML 标签），如 "Your IP address has been temporarily banned ... The ban expires in 59 minutes"
    public static func banMessage(in text: String) -> String? {
        guard let r = text.range(of: banMarker) else { return nil }
        let tail = text[r.lowerBound...].prefix(400)
        let stripped = tail.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? banMarker : stripped
    }

    /// 传输层错误 → EhError
    public static func map(_ error: Error) -> Error {
        if error is EhError { return error }
        if error is CancellationError { return EhError.cancelled }
        if let t = error as? EhTransportError {
            switch t {
            case .tooManyRedirects: return EhError.network(t.description)
            default: return EhError.network(t.description)
            }
        }
        return EhError.network(error.localizedDescription)
    }
}
