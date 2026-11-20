import Foundation

/// 个人主页（home.php）额度与 GP 统计。对应 Android `data/HomeDetail`
public struct HomeDetail: Codable, Sendable, Hashable {
    public var used: Int64 = 0
    public var total: Int64 = 0
    public var resetCost: Int64 = 0
    public var fromGalleryVisits: Int64 = 0
    public var fromTorrentCompletions: Int64 = 0
    public var fromArchiveDownloads: Int64 = 0
    public var fromHentaiAtHome: Int64 = 0
    public var currentModerationPower: Int64 = 0

    public init() {}

    /// 对应 `getResetCost()` 等：带 " Gp" 后缀的显示文本
    public var resetCostText: String { Self.withGp(resetCost) }
    public var fromGalleryVisitsText: String { Self.withGp(fromGalleryVisits) }
    public var fromTorrentCompletionsText: String { Self.withGp(fromTorrentCompletions) }
    public var fromArchiveDownloadsText: String { Self.withGp(fromArchiveDownloads) }
    public var fromHentaiAtHomeText: String { Self.withGp(fromHentaiAtHome) }
    public var currentModerationPowerText: String { String(currentModerationPower) }

    /// 对应 `getImageLimits(Context)`：total 为 0（IP 限制，非账号额度）时返回 baseLimitsText
    /// （Android 为 R.string.ip_base_limits）
    public func imageLimitsText(baseLimitsText: String) -> String {
        total == 0 ? baseLimitsText : "\(used)/\(total)"
    }

    private static func withGp(_ l: Int64) -> String { "\(l) Gp" }
}
