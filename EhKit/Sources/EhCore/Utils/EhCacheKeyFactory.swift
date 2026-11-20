import Foundation

/// 图片缓存键。对应 Android `EhCacheKeyFactory`
public enum EhCacheKeyFactory {
    public static func getThumbKey(_ gid: Int64) -> String {
        "preview:large:\(gid):0" // 旧版为 "thumb:" + gid
    }

    public static func getNormalPreviewKey(_ gid: Int64, _ index: Int) -> String {
        "preview:normal:\(gid):\(index)"
    }

    public static func getLargePreviewKey(_ gid: Int64, _ index: Int) -> String {
        "preview:large:\(gid):\(index)"
    }

    public static func getLargePreviewSetKey(_ gid: Int64, _ index: Int) -> String {
        "large_preview_set:\(gid):\(index)"
    }

    public static func getImageKey(_ gid: Int64, _ index: Int) -> String {
        "image:\(gid):\(index)"
    }
}
