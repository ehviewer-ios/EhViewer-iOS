import Foundation

/// 站点 URL 构造。对应 Android `EhUrl`。所有依赖站点的函数都显式传入 `EhSite`，不读全局设置。
public enum EhURL {
    public static let domainForums = "forums.e-hentai.org"
    public static let apiSignIn = "https://forums.e-hentai.org/index.php?act=Login&CODE=01"
    public static let signIn = "https://forums.e-hentai.org/index.php?act=Login"
    public static let register = "https://forums.e-hentai.org/index.php?act=Reg&CODE=00"
    public static let forums = "https://forums.e-hentai.org/"
    public static let news = "https://e-hentai.org/news.php"
    public static let homeE = "https://e-hentai.org/home.php"
    public static let topList = "https://e-hentai.org/toplist.php"
    public static let thumbPrefixE = "https://ehgt.org/"

    public static func host(_ site: EhSite) -> String { site.host }
    public static func api(_ site: EhSite) -> String { site.host + "api.php" }
    public static func home(_ site: EhSite) -> String { site.host + "home.php" }
    public static func popular(_ site: EhSite) -> String { "https://\(site.domain)/popular" }
    public static func favorites(_ site: EhSite) -> String { site.host + "favorites.php" }
    public static func uconfig(_ site: EhSite) -> String { site.host + "uconfig.php" }
    public static func myTags(_ site: EhSite) -> String { site.host + "mytags" }
    public static func watched(_ site: EhSite) -> String { site.host + "watched" }

    public static func imageSearch(_ site: EhSite) -> String {
        site == .e ? "https://upld.e-hentai.org/image_lookup.php" : "https://upld.exhentai.org/upld/image_lookup.php"
    }

    public static func galleryDetail(_ site: EhSite, gid: Int64, token: String, page: Int = 0, allComments: Bool = false) -> String {
        var s = site.host + "g/\(gid)/\(token)/"
        var q: [String] = []
        if page != 0 { q.append("p=\(page)") }
        if allComments { q.append("hc=1") }
        if !q.isEmpty { s += "?" + q.joined(separator: "&") }
        return s
    }

    /// index 从 0 开始
    public static func page(_ site: EhSite, gid: Int64, index: Int, pToken: String) -> String {
        site.host + "s/\(pToken)/\(gid)-\(index + 1)"
    }

    public static func addFavorites(_ site: EhSite, gid: Int64, token: String) -> String {
        site.host + "gallerypopups.php?gid=\(gid)&t=\(token)&act=addfav"
    }

    public static func archiver(_ site: EhSite, gid: Int64, token: String, or: String) -> String {
        let base = site.host + "archiver.php?gid=\(gid)&token=\(token)"
        return or.isEmpty ? base : base + "&or=\(or)"
    }

    public static func torrentList(_ site: EhSite, gid: Int64, token: String) -> String {
        site.host + "gallerytorrents.php?gid=\(gid)&t=\(token)"
    }

    public static func tagDefinition(_ tag: String) -> String {
        "https://ehwiki.org/wiki/" + tag.replacingOccurrences(of: " ", with: "_")
    }

    /// 对应 `getFixedPreviewThumbUrl`：把 `.../ab/cd/abcd...jpg` 形式的缩略图改写到 ehgt.org
    public static func fixedPreviewThumbUrl(_ origin: String) -> String {
        guard let url = URL(string: origin) else { return origin }
        let segs = url.pathComponents.filter { $0 != "/" }
        guard segs.count >= 3 else { return origin }
        let last = segs[segs.count - 1], second = segs[segs.count - 2], third = segs[segs.count - 3]
        if last.hasPrefix(third), last.dropFirst(third.count).hasPrefix(second) {
            return thumbPrefixE + third + "/" + second + "/" + last
        }
        return origin
    }
}
