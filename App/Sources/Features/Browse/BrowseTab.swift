import SwiftUI
import EhCore
import EhStorage

/// 浏览页的数据源（标题菜单切换）。对应 Android 抽屉中的 首页 / 订阅 / 热门 / 排行榜 / News
enum BrowseSource: String, CaseIterable, Hashable {
    case home, subscription, popular, topList, news

    var title: String {
        switch self {
        case .home: return "首页"
        case .subscription: return "订阅"
        case .popular: return "热门"
        case .topList: return "排行榜"
        case .news: return "News"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .subscription: return "tag"
        case .popular: return "flame"
        case .topList: return "trophy"
        case .news: return "newspaper"
        }
    }

    init(launchPage: EhSettings.LaunchPage) {
        switch launchPage {
        case .homepage: self = .home
        case .subscription: self = .subscription
        case .whatsHot: self = .popular
        }
    }
}

/// 浏览标签页：NavigationStack 根 + 标题菜单切换数据源
struct BrowseTab: View {
    @Environment(AppModel.self) private var model
    @State private var path = NavigationPath()
    @State private var source: BrowseSource?
    @State private var showSignIn = false

    var body: some View {
        NavigationStack(path: $path) {
            root
                .toolbarTitleMenu {
                    Picker("数据源", selection: sourceBinding) {
                        ForEach(BrowseSource.allCases, id: \.self) { s in
                            Label(s.title, systemImage: s.systemImage).tag(s)
                        }
                    }
                }
                .withAppRoutes()
        }
        .navigate(appendingTo: $path)
        .onAppear {
            if source == nil { source = BrowseSource(launchPage: model.setting(\.launchPage)) }
        }
        // 外部链接 / 剪贴板等请求打开的页面
        .onChange(of: model.router.pendingRoute, initial: true) { _, route in
            guard let route else { return }
            path.append(route)
            model.router.pendingRoute = nil
        }
    }

    private var sourceBinding: Binding<BrowseSource> {
        Binding(get: { source ?? .home }, set: { source = $0 })
    }

    @ViewBuilder
    private var root: some View {
        switch source ?? BrowseSource(launchPage: model.setting(\.launchPage)) {
        case .home:
            GalleryListView(builder: .home, title: BrowseSource.home.title)
                .id(BrowseSource.home)
        case .subscription:
            if model.isSignedIn {
                GalleryListView(builder: ListUrlBuilder(mode: .subscription), title: BrowseSource.subscription.title)
                    .id(BrowseSource.subscription)
            } else {
                ContentUnavailableView {
                    Label("需要登录", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text("登录后可以查看订阅标签的画廊。")
                } actions: {
                    Button("登录") { showSignIn = true }
                        .buttonStyle(.borderedProminent)
                }
                .sheet(isPresented: $showSignIn) { SignInSheet() }
                    .navigationTitle(BrowseSource.subscription.title)
                    .navigationBarTitleDisplayMode(.inline)
            }
        case .popular:
            GalleryListView(builder: ListUrlBuilder(mode: .whatsHot), title: BrowseSource.popular.title)
                .id(BrowseSource.popular)
        case .topList:
            TopListView()
        case .news:
            NewsView()
        }
    }
}
