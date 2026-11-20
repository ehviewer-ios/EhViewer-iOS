import Foundation

/// 统一错误类型。对应 Android `client/exception/*`
public enum EhError: Error, Sendable, Equatable, LocalizedError {
    /// HTML 结构无法解析（站点改版或返回了异常页）。body 截断保留前 512 字符便于诊断
    case parse(String, body: String? = nil)
    /// 被 ban / IP 被封（页面包含 "Your IP address has been temporarily banned"）
    case banned(String)
    /// 需要登录或权限不足（里站未登录返回空白页等）
    case noHAtH
    case notSignedIn
    /// 509：图片配额用尽
    case image509
    /// 站点返回的业务错误（如 "This gallery has been removed"）
    case server(String)
    /// 画廊被标记为 offensive，需要 nw=1 / 确认
    case offensive
    /// 画廊被删除 / pining for the fjords
    case pining
    case http(status: Int)
    case cancelled
    case network(String)
    case quotaExceeded
    /// Cloudflare 人机验证页（需要在浏览器 / WebView 中完成验证）。关联值为被拦截的域名
    case cloudflareChallenge(String)
    case other(String)

    public var errorDescription: String? {
        switch self {
        case let .parse(msg, _): return "解析失败：\(msg)"
        case let .banned(msg): return "IP 被封禁：\(msg)"
        case .noHAtH: return "此功能需要 H@H"
        case .notSignedIn: return "请先登录"
        case .image509: return "图片配额已用尽（509）"
        case let .server(msg): return msg
        case .offensive: return "该画廊包含冒犯性内容，需确认后访问"
        case .pining: return "该画廊已被删除"
        case let .http(status): return "HTTP 错误 \(status)"
        case .cancelled: return "已取消"
        case let .network(msg): return "网络错误：\(msg)"
        case .quotaExceeded: return "超出配额"
        case let .cloudflareChallenge(host): return "\(host) 开启了 Cloudflare 人机验证，无法直接访问，请改用网页登录"
        case let .other(msg): return msg
        }
    }

    public static func parseFailure(_ message: String, html: String) -> EhError {
        .parse(message, body: String(html.prefix(512)))
    }
}
