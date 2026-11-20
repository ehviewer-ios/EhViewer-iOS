import Foundation
import SwiftUI
import EhCore
import EhNetwork
import EhStorage
import EhSpider

extension EhFilter: @retroactive EhGalleryFiltering {}

/// 组合根：持有所有长生命周期服务。见 docs/APP_DESIGN.md
@MainActor @Observable
final class AppModel {
    // MARK: 服务
    let directories: AppDirectories
    let settings: EhSettings
    let database: EhDatabase
    let cookieStore: EhCookieStore
    let http: EhHTTPClient
    let api: EhAPI
    let filter: EhFilter
    let tagUpdater: TagTranslationUpdater
    /// 阅读加载器注册表（在线阅读与下载共享）
    let loaderRegistry: GalleryLoaderRegistry
    let downloads: DownloadManager
    let archiver: ArchiverDownloader
    /// 下载画廊的标签（下载列表的标签搜索）
    let downloadTags: DownloadTagIndex
    let toast = ToastCenter()
    let lock: AppLockModel
    let router = Router()

    // MARK: 可观察状态
    /// 设置修改计数。读取设置的视图通过 `binding(_:)` 访问即可自动刷新
    private(set) var settingsRevision = 0
    private(set) var tagTranslation: TagTranslation?
    var isSignedIn: Bool
    var displayName: String?
    var avatarURL: String?
    /// 数据库或设置启动失败时的致命错误
    private(set) var startupError: String?
    /// 当前要展示的阅读器
    var readerRequest: ReaderRequest?

    var site: EhSite {
        get { _ = settingsRevision; return settings.gallerySite }
        set {
            settings.gallerySite = newValue
            settingsDidChange(network: true)
        }
    }

    init() {
        let dirs = AppDirectories.standard()
        directories = dirs
        settings = EhSettings()
        settings.fixDefaultValue(regionCode: Locale.current.region?.identifier)
        lock = AppLockModel(settings: settings)

        var startupError: String?
        let db: EhDatabase
        do {
            db = try EhDatabase(url: dirs.databaseURL)
        } catch {
            startupError = "数据库打开失败：\(error.localizedDescription)"
            // swiftlint:disable:next force_try
            db = try! EhDatabase.inMemory()
        }
        database = db
        filter = (try? EhFilter(database: db)) ?? { try! EhFilter(database: EhDatabase.inMemory()) }()

        let cookieFile = dirs.applicationSupport.appendingPathComponent("cookies.json")
        cookieStore = EhCookieStore(persistence: JSONFileCookiePersistence(fileURL: cookieFile))

        http = EhHTTPClient(config: Self.networkConfig(from: settings), cookieStore: cookieStore)
        AppImagePipeline.configure(client: http)

        let settingsRef = settings
        let cookieRef = cookieStore
        let filterRef = filter
        let dbRef = db
        let hooks = EhAPIHooks(
            galleryFilter: filterRef,
            isLocalFavorite: { gid in (try? dbRef.containLocalFavorites(gid: gid)) ?? false },
            isBlacklisted: { user in filterRef.isBlacklisted(user) }
        )
        api = EhAPI(client: http, hooks: hooks, environment: {
            EhAPIEnvironment(
                site: settingsRef.gallerySite,
                thumbResolution: settingsRef.thumbResolution.rawValue,
                fixThumbUrl: settingsRef.fixThumbUrl,
                showGalleryPages: settingsRef.showGalleryPages,
                isLogin: cookieRef.hasSignedIn
            )
        })

        let tagDir = dirs.filesDir("tag-translations") ?? dirs.applicationSupport
        tagUpdater = TagTranslationUpdater(client: http, directory: tagDir)

        let spiderEnv = Self.spiderEnvironment(settings: settings, directories: dirs, database: db, http: http)
        let registry = GalleryLoaderRegistry(environment: spiderEnv)
        loaderRegistry = registry
        let manager = DownloadManager(database: db, registry: registry, location: spiderEnv.location,
                                      spiderInfoCache: spiderEnv.spiderInfoCache,
                                      downloadOrderAsc: settings.downloadOrderAsc)
        downloads = manager
        downloadTags = DownloadTagIndex(database: db)
        let tempDir = dirs.tempDir ?? FileManager.default.temporaryDirectory
        archiver = ArchiverDownloader(
            provider: DefaultArchiveProvider(client: http, site: settings.gallerySite),
            directory: dirs.archiverDir ?? tempDir,
            completion: { zip, info, _ in
                _ = try await manager.importDownloadedArchive(zip: zip, galleryInfo: info, tempDirectory: tempDir)
            }
        )

        isSignedIn = cookieStore.hasSignedIn
        displayName = settings.displayName
        avatarURL = settings.avatar
        self.startupError = startupError

        Task { await self.loadTagTranslation() }
        Task { await self.archiver.resumePending() }
    }

    static func spiderEnvironment(settings: EhSettings, directories: AppDirectories, database: EhDatabase,
                                  http: EhHTTPClient) -> SpiderEnvironment {
        var env = SpiderEnvironment(
            site: settings.gallerySite,
            provider: DefaultGalleryPageProvider(client: http, site: settings.gallerySite, fixThumbUrl: settings.fixThumbUrl),
            directories: directories, database: database, downloadRoot: nil, settings: settings
        )
        // 页失败原因、限流暂停、补下轮次写入下载日志
        env.diagnostics = { DownloadLog.write($0) }
        return env
    }

    // MARK: 设置

    static func networkConfig(from s: EhSettings) -> EhNetworkConfig {
        var c = EhNetworkConfig()
        c.site = s.gallerySite
        c.domainFronting = s.domainFronting
        c.builtInHosts = s.builtInHosts
        c.builtInExHosts = s.builtExHosts
        c.dnsOverHttps = s.doH
        c.proxyType = EhProxyType(rawValue: s.proxyType.rawValue) ?? .system
        c.proxyHost = s.proxyIp
        c.proxyPort = s.proxyPort
        c.userHosts = CustomHostsStore.table
        return c
    }

    /// 设置改变后调用；`network` 为 true 时重建网络配置
    func settingsDidChange(network: Bool = false) {
        settingsRevision &+= 1
        if network {
            let config = Self.networkConfig(from: settings)
            Task { await http.updateConfig(config) }
        }
        // 站点、线程数、预加载等变化需要更新加载器环境（对之后新建的加载器生效）
        let env = Self.spiderEnvironment(settings: settings, directories: directories, database: database, http: http)
        Task { await loaderRegistry.updateEnvironment { $0 = env } }
        downloads.downloadOrderAsc = settings.downloadOrderAsc
    }

    /// 为 EhSettings 的属性生成 SwiftUI Binding
    func binding<T>(_ keyPath: ReferenceWritableKeyPath<EhSettings, T>, network: Bool = false) -> Binding<T> {
        Binding(
            get: { _ = self.settingsRevision; return self.settings[keyPath: keyPath] },
            set: { self.settings[keyPath: keyPath] = $0; self.settingsDidChange(network: network) }
        )
    }

    /// 读取设置并登记依赖（视图中读取设置时用它，以便设置变更后刷新）
    func setting<T>(_ keyPath: KeyPath<EhSettings, T>) -> T {
        _ = settingsRevision
        return settings[keyPath: keyPath]
    }

    // MARK: 账号

    func refreshSignInState() {
        isSignedIn = cookieStore.hasSignedIn
        settings.isLogin = isSignedIn
        settingsDidChange()
    }

    /// 登录后获取昵称与头像
    func fetchProfile() async {
        var profile = try? await api.getProfile()
        if profile?.displayName?.isEmpty ?? true {
            // 论坛开启 Cloudflare 人机验证时普通请求会被拦截，改用 WebView 读取（对应 Android GetProfileScene）
            if let web = await WebProfileFetcher.fetch(cookies: cookieStore.exportHTTPCookies()) {
                profile = web
            }
        }
        guard let profile, let name = profile.displayName, !name.isEmpty else { return }
        displayName = name
        settings.displayName = name
        if let avatar = profile.avatar {
            avatarURL = avatar
            settings.avatar = avatar
        }
    }

    func signOut() {
        cookieStore.signOut()
        Task { await WebSiteData.clearEhCookies() }
        settings.displayName = nil
        settings.avatar = nil
        settings.needSignIn = true
        displayName = nil
        avatarURL = nil
        refreshSignInState()
    }

    // MARK: 标签翻译

    func loadTagTranslation() async {
        if let t = await tagUpdater.instance() {
            tagTranslation = t
        }
        if let t = await tagUpdater.update() {
            tagTranslation = t
        }
    }

    /// 根据设置返回 tag 的显示文本
    func displayTag(_ tag: String, namespace: String? = nil) -> String {
        guard setting(\.showTagTranslations), let t = tagTranslation else { return tag }
        let key: String
        if let namespace, var prefix = TagTranslation.namespaceToPrefix(namespace) {
            if !prefix.isEmpty, !prefix.hasSuffix(":") { prefix += ":" }
            key = prefix + tag
        } else {
            key = tag
        }
        return t.getTranslation(key) ?? t.getTranslation(tag) ?? tag
    }

    /// 命名空间（tag 分组名）的显示文本，如 female -> 女性
    func displayNamespace(_ namespace: String) -> String {
        guard setting(\.showTagTranslations), let t = tagTranslation else { return namespace }
        return t.getTranslation("n:" + namespace) ?? namespace
    }

    /// 适合当前设置的画廊标题
    func title(of info: GalleryInfo) -> String {
        info.suitableTitle(preferJapanese: setting(\.showJpnTitle))
    }
}

/// 各 NavigationStack 共享的路由（由各 Tab 自己持有 path，这里只放全局跳转请求）
@MainActor @Observable
final class Router {
    /// 外部链接打开的画廊，由根视图监听并展示
    var pendingRoute: Route?
    /// 请求切换到某个标签页（由根视图监听并清空）
    var requestedTab: RootView.AppTab?
}

extension AppModel {
    /// 切换到“下载”标签页（会关闭阅读器）
    func showDownloads() {
        readerRequest = nil
        router.requestedTab = .downloads
    }
}
