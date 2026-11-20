import Foundation

/// 种子条目。对应 Android `data/TorrentInfo`
public struct TorrentInfo: Codable, Sendable, Hashable {
    /// 已去掉 `?p=` 个人化参数的种子地址
    public var url: String
    public var name: String
    public var posted: String

    public init(url: String, name: String, posted: String) {
        self.url = url
        self.name = name
        self.posted = posted
    }
}
