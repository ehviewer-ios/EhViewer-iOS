# EhViewer iOS —— App 层设计

所有非 UI 逻辑在 `EhKit`（见 `PORTING.md`）。本文件规定 App 层（`App/Sources/`）的结构与交互。
交互按 iOS 习惯重新设计，不照搬 Android 的抽屉/FAB/Scene 栈。

## 技术基线
- SwiftUI（iOS 17+），状态用 Observation（`@Observable`、`@Environment(Type.self)`、`@Bindable`）。不要用 Combine 的 `ObservableObject`，除非 EhKit 的类型本身是。
- 阅读器、需要高性能的大列表细节可用 UIKit（`UIViewControllerRepresentable`）。
- 图片：Nuke / NukeUI（`LazyImage`），统一使用 `AppImagePipeline.shared`（自定义 DataLoader 走 `EhHTTPClient`，以支持域前置、Cookie、Referer）。
- 文案：中文直接写在 `Text("…")` 中（开发语言 zh-Hans，之后由 Xcode 抽取 String Catalog）。
- 构建验证：在 Mac 上运行 `scripts/build-sim.sh`（xcodegen + xcodebuild 模拟器编译，输出错误摘要）。

## 目录
```
App/Sources/
  EhViewerApp.swift          @main，注入 AppModel
  Core/                      AppModel（组合根）、Router、AppImagePipeline、Haptics、Formatters、扩展
  Components/                复用视图：GalleryRow、GalleryGridCell、CategoryBadge、RatingView、TagChip、ThumbnailImage、EmptyStateView、ErrorView、LoadMoreFooter …
  Features/
    Browse/                  画廊列表（首页/搜索/热门/订阅/上传者/标签/图片搜索结果）、搜索与高级搜索、快速搜索
    TopList/                 排行榜
    Favorites/               云端收藏（10 个收藏夹）+ 本地收藏
    Detail/                  画廊详情、标签、评论、预览缩略图、种子、归档、评分、收藏对话框、新版本
    Reader/                  阅读器（UIKit）及设置面板
    Downloads/               下载列表、标签管理、导入
    History/                 历史
    Account/                 登录（账号密码 / Cookie / 网页）、个人主页额度、My Tags / Watched、uconfig（WKWebView）
    News/                    E-Hentai News
    Settings/                设置各分组、过滤器、黑名单、hosts、网络、隐私、高级、关于
    Transfer/                Wi-Fi 互传（扫码 / 显示二维码）
    Security/                应用锁（Face ID / 密码）、隐私遮罩
```

## 导航（iPhone）
`TabView` 五个标签：
1. **浏览**：`NavigationStack`，根视图为画廊列表。导航栏标题处是一个菜单（`Menu`）切换数据源：首页 / 订阅（Watched）/ 热门 / 排行榜 / News。右上角：列表↔网格切换、快速搜索。顶部 `.searchable`，带标签翻译建议（`TagTranslation.suggest`）与搜索历史；搜索范围（关键词/上传者/标签）用 search scopes；高级搜索与分类筛选通过工具栏按钮弹出 sheet。
2. **收藏**：顶部 `Picker` 切换收藏夹（全部 / 0–9 / 本地），显示每个收藏夹数量；支持搜索收藏、多选移动/删除。
3. **下载**：按标签分组（顶部标签筛选 Menu），行内进度条与速度；左滑 删除/暂停，右滑 开始；多选批量；右上角 "+" 导入（zip / 文件夹 / Android 下载目录）。
4. **历史**：列表，左滑删除，清空按钮。
5. **我的**：账号卡片（头像、昵称、额度 HomeDetail、重置额度）、My Tags、站点切换（E/EX）、设置入口、Wi-Fi 互传、关于。

iPad：同一套 TabView（iOS 18 起可 `.tabViewStyle(.sidebarAdaptable)`，用 `if #available` 包裹）。详情页在宽屏下用两栏布局（左封面+信息，右标签+预览）。

路由：`enum Route: Hashable`（`.gallery(GalleryInfo)`、`.galleryURL(gid, token)`、`.list(ListUrlBuilder)`、`.comments(GalleryDetail)`、`.previews(GalleryDetail)`、`.torrents(...)`、`.uploader(String)`、`.tag(String)` …），各 `NavigationStack` 用 `.navigationDestination(for: Route.self)`，由 `RouteDestination` 统一构造视图。阅读器用 `.fullScreenCover`。
程序化跳转用 `@Environment(\.navigate)`（追加到标签页持有的 path，标签页在 NavigationStack 上调用 `.navigate(appendingTo: $path)`）。页面内不要再用 `navigationDestination(item:)`：与 path 混用时，之后经 path 压入的页面会被 item 方式打开的页面盖住。
外部链接：`onOpenURL` 处理 `ehviewer://` 与 e-hentai/exhentai 链接（`EhUrlOpener` 路由判断），剪贴板检测画廊链接时弹提示条。

## 交互调整（相对 Android）
- 侧边抽屉 → TabView + 标题菜单；悬浮按钮 → 导航栏按钮。
- 长按画廊 → `contextMenu`（下载、收藏、复制链接、分享、加入本地收藏、按上传者搜索、预览大图（context menu preview））。
- 下拉刷新 `.refreshable`；分页为无限滚动（滚到底自动加载下一页，支持跳页 Menu：输入页码/日期跳转 seek）。
- 对话框 → `confirmationDialog` / `sheet`（带 `presentationDetents`）。
- Toast → 顶部轻提示（自定义 `ToastCenter`）。
- 详情页 tag 点击 → 菜单（搜索此标签 / 复制 / 投票(up/down) / 查看定义 / 加入过滤器 / 关注）。
- 阅读器：轻点中间呼出/隐藏工具栏；左右边缘点击翻页（方向按阅读方向）；双击缩放、捏合缩放；底部滑块跳页（带缩略图气泡）；工具栏：阅读方向、缩放模式、亮度、保存到相册、分享、刷新当前页、原图、自动翻页；支持键盘/音量键翻页（音量键用 `AVAudioSession` 观察 outputVolume，可选）。纵向条漫模式用连续滚动的 `UICollectionView`。
- 应用锁：应用锁、后台隐私遮罩（不透明）与轻提示位于顶层覆盖窗口（`Core/OverlayWindow.swift`），覆盖所有 sheet 与全屏阅读器；返回前台按宽限时间要求 Face ID / 设备密码（`LocalAuthentication`）。Android 的图案锁不移植。

## 后台与系统集成
- 下载（`Core/BackgroundDownloads.swift`）：
  - iOS 26+：有下载时（开始下载、即将离开 App）提交持续处理任务 `BGContinuedProcessingTask`（标识 `<Bundle ID>.continuedDownload.<UUID>`，系统要求以 Bundle ID 开头），切到后台后继续运行。每秒汇报进度，每个画廊或归档占 1000 份。任务被系统结束时，与后台时间耗尽的处理相同。
  - 否则：进入后台调用 `UIApplication.beginBackgroundTask` 并通知 `DownloadManager.enterBackground()`；时间耗尽时暂停，登记 `BGProcessingTask`（标识 `<Bundle ID>.download`，从 Info.plist 读取）续跑。
  - 诊断日志 `DownloadLog`（Library/Caches/download.log，同时记录页失败原因、限流与补下）。下载完成发本地通知（`UNUserNotificationCenter`，用户第一次开始下载时请求权限）。
- 文件：下载目录在 Documents/download，"文件" App 可见。导入用 `.fileImporter`。
- 分享：`ShareLink`。

## 组合根 AppModel（`Core/AppModel.swift`）
`@MainActor @Observable final class AppModel`，App 启动时创建，持有：
`settings: EhSettings`、`database: EhDatabase`、`cookieStore: EhCookieStore`、`http: EhHTTPClient`、`api: EhAPI`、`downloads: DownloadManager`、`tagTranslation: TagTranslation?`、`filter: EhFilter`、`account`（登录状态、昵称、头像）、`site: EhSite`（与 settings 同步）、`toast: ToastCenter`、`lock: AppLockModel`。
设置变化影响网络时调用 `applyNetworkSettings()` 生成新的 `EhNetworkConfig`。
各 Feature 的 ViewModel 都是 `@Observable` 类，从 `AppModel` 取依赖，不直接创建网络/数据库对象。

## 交互规范（HIG 审查后的约定）
- 轻提示只用于"结果在界面上看不到"的操作（复制、错误、后台完成）；界面已有状态变化时改用触感反馈（`.sensoryFeedback` / `Haptics`）。sheet 内的错误就地呈现（`.alert` 或 footer）。
- 可点的行用 `Button(.plain)` / `NavigationLink`，不用 `onTapGesture`；触控区 ≥ 44pt；不写死字号；图标按钮有 `accessibilityLabel`；选中态加 `.isSelected`。
- 只有不可撤销且有代价的操作才确认（删除文件、消耗 GP）；`confirmationDialog` 标题简短、说明放 `message`；菜单中破坏性项放末尾 Section。
- 系统权限（通知、相册、相机、本地网络）在用户首次触发相关功能时请求，被拒后提供"前往设置"。
- 跨 Tab 跳转用 `model.router.requestedTab` / `model.showDownloads()`；页面跳转用 `model.router.pendingRoute`。
- 列表页（画廊列表、下载、收藏、历史）的搜索栏在列表顶部，下滑时随导航栏收起（`.navigationBarDrawer(displayMode: .automatic)`，见 `Components/ListSearch.swift`）；导航栏另有搜索按钮（`ListSearchButton`），翻到多深都能一点打开搜索栏修改搜索词。没有用 iOS 26 的 `searchToolbarBehavior(.minimize)`：在标签栏 App 中点展开后的关闭按钮无法退出搜索（iOS 27.2 实测，最小示例可复现）。
- 画廊列表与下载列表的搜索共用 `Components/SubmittedSearch.swift`（`SubmittedSearchState` + `.submittedSearch`）：
  - 提交后收起搜索框，让导航栏按钮恢复显示；搜索框保留当前条件对应的搜索词。标签、上传者页使用站点搜索语法，如 `female:"big breasts$"`，获得焦点时光标在末尾，可直接追加条件。
  - 取消编辑不改变列表；清空搜索框后取消则回到初始列表（也可用条件栏的“重置”）。
  - 建议面板由列表自己绘制（`BrowseSearchSuggestions`），不用系统的 `.searchSuggestions`，因为系统面板中点按任何一行都会直接提交。点搜索历史直接搜索；点标签建议只替换输入末尾的关键字、不提交（同 Android），便于组合多个标签。
- 下载列表：
  - 点击行阅读，点击封面进入详情（与 Android 一致）。
  - 搜索：编辑中实时筛选，提交后保留。语法与站点相同（`LocalGallerySearch`），匹配标题、上传者、下载标签与画廊标签。
  - 标签存于 `Gallery_Tags`：打开详情页时写入，缺少的用 gdata 补齐（`DownloadTagIndex`）。标签建议只列出下载中出现过的标签。
