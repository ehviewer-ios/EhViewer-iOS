import SwiftUI
import EhCore

/// 根视图：五个标签页。见 docs/APP_DESIGN.md「导航」
struct RootView: View {
    @Environment(AppModel.self) private var model
    // 调试：启动参数 -EHInitialTab favorites|downloads|history|me
    @State private var debugWebSignIn = false
    @State private var tab: AppTab = AppTab(debugName: UserDefaults.standard.string(forKey: "EHInitialTab")) ?? .browse

    enum AppTab: Hashable {
        case browse, favorites, downloads, history, me

        init?(debugName: String?) {
            switch debugName {
            case "favorites": self = .favorites
            case "downloads": self = .downloads
            case "history": self = .history
            case "me": self = .me
            default: return nil
            }
        }
    }

    var body: some View {
        tabs
        .preferredColorScheme(model.preferredColorScheme)
        .environment(model.lock)
        // 应用锁、隐私遮罩、轻提示位于顶层覆盖窗口（盖住 sheet 与阅读器）
        .background(OverlayWindowInstaller(model: model))
        .onOpenURL { model.handleOpenURL($0) }
        .task { DownloadNotifier.shared.start(model) }
        .task {
            // 调试：启动参数 -EHDebugRoute settings:eh|topList|news|transfer|myTags
            if let r = UserDefaults.standard.string(forKey: "EHDebugRoute") {
                let parts = r.split(separator: ":").map(String.init)
                switch parts.first {
                case "settings": model.router.pendingRoute = SettingsPage(rawValue: parts.last ?? "").map { .settings($0) }
                case "topList": model.router.pendingRoute = .topList
                case "news": model.router.pendingRoute = .news
                case "transfer": model.router.pendingRoute = .transfer
                case "myTags": model.router.pendingRoute = .myTags
                case "webSignIn": debugWebSignIn = true
                default: break
                }
            }
            // 调试：启动参数 -EHOpenURL <链接>
            if let s = UserDefaults.standard.string(forKey: "EHOpenURL"), let url = URL(string: s) {
                model.handleOpenURL(url)
                if UserDefaults.standard.bool(forKey: "EHOpenReader"),
                   case let .galleryDetail(gid, token)? = EhUrlRoute.parseEhUrl(s) {
                    model.openReader(GalleryInfo(gid: gid, token: token, title: "调试"), page: 0)
                }
                if UserDefaults.standard.bool(forKey: "EHStartDownload"),
                   case let .galleryDetail(gid, token)? = EhUrlRoute.parseEhUrl(s) {
                    let list = await model.api.fillGalleryListByApiBestEffort([GalleryInfo(gid: gid, token: token)],
                                                                             referer: model.site.referer)
                    if let info = list.first { model.startDownload(info) }
                }
            }
        }
        .onChange(of: model.router.requestedTab) { _, t in
            if let t {
                tab = t
                model.router.requestedTab = nil
            }
        }
        .onChange(of: model.router.pendingRoute) { _, route in
            if route != nil { tab = .browse }
        }
        .sheet(isPresented: $debugWebSignIn) {
            NavigationStack { WebSignInView(onSuccess: { _ in debugWebSignIn = false }) }
        }
        .fullScreenCover(item: Bindable(model).readerRequest) { request in
            ReaderView(request: request)
                .environment(model)
                .environment(model.lock)
        }
    }

    /// iOS 18+ 使用新 Tab API：iPhone 为标签栏，iPad 可切换为侧边栏
    @ViewBuilder private var tabs: some View {
        if #available(iOS 18, *) {
            TabView(selection: $tab) {
                Tab("浏览", systemImage: "square.grid.2x2", value: AppTab.browse) { BrowseTab() }
                Tab("收藏", systemImage: "heart", value: AppTab.favorites) { FavoritesTab() }
                Tab("下载", systemImage: "arrow.down.circle", value: AppTab.downloads) { DownloadsTab() }
                Tab("历史", systemImage: "clock", value: AppTab.history) { HistoryTab() }
                Tab("我的", systemImage: "person.crop.circle", value: AppTab.me) { MeTab() }
            }
            .tabViewStyle(.sidebarAdaptable)
        } else {
            TabView(selection: $tab) {
                BrowseTab()
                    .tabItem { Label("浏览", systemImage: "square.grid.2x2") }
                    .tag(AppTab.browse)
                FavoritesTab()
                    .tabItem { Label("收藏", systemImage: "heart") }
                    .tag(AppTab.favorites)
                DownloadsTab()
                    .tabItem { Label("下载", systemImage: "arrow.down.circle") }
                    .tag(AppTab.downloads)
                HistoryTab()
                    .tabItem { Label("历史", systemImage: "clock") }
                    .tag(AppTab.history)
                MeTab()
                    .tabItem { Label("我的", systemImage: "person.crop.circle") }
                    .tag(AppTab.me)
            }
        }
    }
}
