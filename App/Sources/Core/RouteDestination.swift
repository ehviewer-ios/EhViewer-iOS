import SwiftUI
import EhCore

/// Route -> 视图。各功能任务只实现被引用的视图类型，不修改此文件（需要新路由时由主会话添加）
struct RouteDestination: View {
    let route: Route

    var body: some View {
        switch route {
        case let .gallery(info, _):
            GalleryDetailView(info: info)
        case let .galleryToken(gid, token):
            GalleryDetailView(gid: gid, token: token)
        case let .list(builder, title):
            GalleryListView(builder: builder, title: title)
        case let .comments(detail):
            GalleryCommentsView(detail: detail)
        case let .previews(detail):
            GalleryPreviewsView(detail: detail)
        case let .torrents(detail):
            TorrentListView(detail: detail)
        case .topList:
            TopListView()
        case .news:
            NewsView()
        case .watched:
            GalleryListView(builder: ListUrlBuilder(mode: .subscription), title: "订阅")
        case .myTags:
            MyTagsView()
        case let .settings(page):
            SettingsPageView(page: page)
        case .transfer:
            TransferView()
        }
    }
}

// MARK: - 程序化跳转

/// 在当前标签页的导航栈中压入页面：`@Environment(\.navigate) private var navigate` → `navigate(.gallery(info))`。
///
/// 所有程序化跳转都追加到标签页持有的同一个 `NavigationPath`，不要在页面内另用 `navigationDestination(item:)`：
/// 两种方式混用时，之后通过 path 压入的页面会被 item 方式打开的页面盖住（例如标签搜索结果中点开的详情页）。
struct NavigateAction {
    fileprivate let push: (Route) -> Void

    func callAsFunction(_ route: Route) { push(route) }
}

extension EnvironmentValues {
    /// 默认不做任何事（在标签页导航栈之外，如预览）
    @Entry var navigate = NavigateAction(push: { _ in })
}

extension View {
    /// 在 NavigationStack 根视图上调用，注册统一路由
    func withAppRoutes() -> some View {
        navigationDestination(for: Route.self) { RouteDestination(route: $0) }
    }

    /// 在标签页的 NavigationStack 上调用：栈内页面的 `navigate` 追加到这个 path
    func navigate(appendingTo path: Binding<NavigationPath>) -> some View {
        environment(\.navigate, NavigateAction { path.wrappedValue.append($0) })
    }
}
