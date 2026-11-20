import Foundation

/// 归档下载对话框（archiver.php）。对应 Android `data/ArchiverData`
public struct ArchiverData: Codable, Sendable, Hashable {
    public var funds: String?
    public var originalCost: String?
    public var originalSize: String?
    /// 原图归档表单 action（POST dltype=org&dlcheck=...）
    public var originalUrl: String?
    public var resampleCost: String?
    public var resampleSize: String?
    /// 重采样归档表单 action（POST dltype=res&dlcheck=...）
    public var resampleUrl: String?

    public init(
        funds: String? = nil, originalCost: String? = nil, originalSize: String? = nil, originalUrl: String? = nil,
        resampleCost: String? = nil, resampleSize: String? = nil, resampleUrl: String? = nil
    ) {
        self.funds = funds; self.originalCost = originalCost; self.originalSize = originalSize
        self.originalUrl = originalUrl; self.resampleCost = resampleCost; self.resampleSize = resampleSize
        self.resampleUrl = resampleUrl
    }
}

/// H@H 归档下载的单个分辨率选项。对应 `ArchiveParser.parse` 返回的 `Pair<res, name>`
public struct ArchiveItem: Codable, Sendable, Hashable {
    /// 分辨率参数（"780"、"1280"、"org" 等），提交为 hathdl_xres
    public var res: String
    /// 显示名（"780x"、"Original"）
    public var name: String

    public init(res: String, name: String) {
        self.res = res
        self.name = name
    }
}
