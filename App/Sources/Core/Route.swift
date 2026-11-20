import Foundation
import EhCore

/// 应用内导航目标。各 Tab 的 NavigationStack 用 `.navigationDestination(for: Route.self) { RouteDestination(route: $0) }`
enum Route: Hashable {
    /// 画廊详情（已有列表信息）。
    /// `origin` 标识来源列表（`GalleryListModel.listID`）：同一画廊已在导航路径中时（如从详情页按标签搜索，
    /// 结果里又出现这个画廊），系统会把值相同的列表行显示为选中状态，加上来源后值就不同了
    case gallery(GalleryInfo, origin: UUID? = nil)
    /// 画廊详情（仅 gid/token，例如来自链接）
    case galleryToken(gid: Int64, token: String)
    /// 画廊列表（搜索、上传者、标签、首页等）
    case list(ListUrlBuilder, title: String? = nil)
    /// 评论
    case comments(GalleryDetail)
    /// 全部预览
    case previews(GalleryDetail)
    /// 种子列表
    case torrents(GalleryDetail)
    case topList
    case news
    case watched
    case myTags
    case settings(SettingsPage)
    case transfer
}

enum SettingsPage: String, Hashable, CaseIterable {
    case eh, read, download, network, privacy, filter, blackList, advanced, about
}

extension ListUrlBuilder {
    static func uploader(_ name: String) -> ListUrlBuilder {
        ListUrlBuilder(mode: .uploader, keyword: name)
    }

    static func tag(_ tag: String) -> ListUrlBuilder {
        ListUrlBuilder(mode: .tag, keyword: tag)
    }

    static var home: ListUrlBuilder { ListUrlBuilder() }
}
