import SwiftUI
import EhCore
import EhStorage
import EhSpider

/// 阅读器（全屏）。SwiftUI 外壳 + UIKit `ReaderViewController`。对应 Android `GalleryActivity`
struct ReaderView: View {
    let request: ReaderRequest
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var vm: ReaderViewModel
    @State private var showSettings = false

    init(request: ReaderRequest) {
        self.request = request
        _vm = State(initialValue: ReaderViewModel(request: request))
    }

    var body: some View {
        @Bindable var vm = vm
        let config = ReaderConfig(model: model)
        let immersive = config.fullscreen && !vm.showChrome
        ZStack {
            Color.black
                .opacity(1 - vm.dismissProgress * 0.6)
                .ignoresSafeArea()
            content(config)
            if vm.dimming > 0 {
                Color.black.opacity(vm.dimming)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            ReaderChrome(vm: vm, config: config, showSettings: $showSettings, close: close)
                .opacity(max(0, 1 - vm.dismissProgress * 3))
            if showGuide {
                ReaderTapGuide(direction: config.direction) {
                    model.binding(\.guideGallery).wrappedValue = false
                }
                .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(immersive)
        .persistentSystemOverlays(immersive ? .hidden : .automatic)
        // 读屏双指 Z 字手势关闭（工具栏获得焦点时也有效）
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) { close() }
        .onAppear { vm.closeAction = close }
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in
            if UIAccessibility.isVoiceOverRunning { vm.showChrome = true }
        }
        .task { await vm.start(model: model) }
        .onDisappear { vm.close() }
        .onChange(of: config, initial: true) { _, new in vm.apply(new) }
        .onChange(of: scenePhase) { _, phase in vm.scenePhaseChanged(active: phase == .active) }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet()
                .environment(model)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .alert("无法保存到相册", isPresented: $vm.showPhotoPermissionAlert) {
            Button("前往设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("没有相册写入权限。请在“设置”中允许 EhViewer 添加照片。")
        }
    }

    /// 首次进入阅读器显示一次点按区域引导（读屏用户不需要）
    private var showGuide: Bool {
        model.setting(\.guideGallery) && vm.pageCount > 0 && !UIAccessibility.isVoiceOverRunning
    }

    @ViewBuilder
    private func content(_ config: ReaderConfig) -> some View {
        if let error = vm.loadError {
            ContentUnavailableView {
                Label("加载失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                if vm.isGallery {
                    Button("重试") { vm.retryLoad() }.buttonStyle(.borderedProminent)
                }
                Button("关闭", action: close)
            }
        } else if vm.pageCount > 0 {
            ReaderContainer(vm: vm, config: config)
                .ignoresSafeArea(edges: config.fullscreen ? .all : [.horizontal, .bottom])
        } else if vm.isPreparing {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("正在加载…").foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { vm.toggleChrome() }
        } else {
            ContentUnavailableView {
                Label("没有图片", systemImage: "photo.on.rectangle.angled")
            } actions: {
                Button("关闭", action: close)
            }
        }
    }

    private func close() {
        vm.close()
        dismiss()
    }
}

// MARK: - UIKit 包装

private struct ReaderContainer: UIViewControllerRepresentable {
    let vm: ReaderViewModel
    let config: ReaderConfig

    func makeUIViewController(context: Context) -> ReaderViewController {
        ReaderViewController(viewModel: vm, config: config)
    }

    func updateUIViewController(_ controller: ReaderViewController, context: Context) {
        controller.apply(config)
    }
}

// MARK: - 页面操作

/// 工具栏“更多”菜单中的页面操作（与页面长按菜单一致）。对应 Android `showPageDialog`
private struct ReaderPageActions: View {
    let vm: ReaderViewModel
    let page: Int

    var body: some View {
        Button { vm.share(page, sourceRect: vm.moreButtonFrame) } label: { Label("分享", systemImage: "square.and.arrow.up") }
        Button { vm.saveToPhotos(page) } label: { Label("保存到相册", systemImage: "square.and.arrow.down") }
        Button { vm.copyImage(page) } label: { Label("复制图片", systemImage: "doc.on.doc") }
        Button { vm.refresh(page) } label: { Label("刷新本页", systemImage: "arrow.clockwise") }
    }
}

// MARK: - 叠加 UI

/// 顶部栏、底部栏（滑块 + 快捷按钮）、状态角标
private struct ReaderChrome: View {
    let vm: ReaderViewModel
    let config: ReaderConfig
    @Binding var showSettings: Bool
    let close: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragPage: Double?
    @State private var isDragging = false

    private func barTransition(_ edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    var body: some View {
        VStack(spacing: 0) {
            if vm.showChrome || vm.pageCount == 0 {
                topBar.transition(barTransition(.top))
            }
            Spacer(minLength: 0)
            if let dragPage, vm.pageCount > 0 {
                ReaderPageBubble(vm: vm, page: Int(dragPage.rounded()))
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
            if vm.showChrome {
                bottomBar.transition(barTransition(.bottom))
            } else if vm.pageCount > 0, config.showClock || config.showProgress || config.showBattery {
                HStack {
                    Spacer()
                    ReaderStatusBadge(config: config, page: vm.currentPage, count: vm.pageCount)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: dragPage == nil)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("关闭")
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.title).font(.headline).lineLimit(1)
                if vm.pageCount > 0 {
                    Text("\(vm.currentPage + 1) / \(vm.pageCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("第 \(vm.currentPage + 1) 页，共 \(vm.pageCount) 页")
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if vm.pageCount > 0 {
                Menu {
                    ReaderPageActions(vm: vm, page: vm.currentPage)
                } label: {
                    // iOS 26 起 ellipsis.circle 在玻璃按钮中会出现双圆圈
                    Image(systemName: "ellipsis")
                        .font(.title3)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("更多")
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    vm.moreButtonFrame = frame
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .modifier(ReaderBarBackground(edge: .top))
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if vm.pageCount > 1 {
                sliderRow
            }
            HStack {
                Menu {
                    Picker("阅读方向", selection: model.binding(\.readingDirection)) {
                        ForEach(EhSettings.ReadingDirection.allCases, id: \.self) {
                            Label($0.readerLabel, systemImage: $0.readerSymbol).tag($0)
                        }
                    }
                } label: {
                    toolbarIcon(config.direction.readerSymbol, "方向")
                }
                Spacer()
                Menu {
                    Picker("缩放方式", selection: model.binding(\.pageScaling)) {
                        ForEach(EhSettings.PageScaling.allCases, id: \.self) { Text($0.readerLabel).tag($0) }
                    }
                } label: {
                    toolbarIcon("arrow.up.left.and.arrow.down.right", "缩放")
                }
                .disabled(config.direction == .topToBottom)
                Spacer()
                Button { vm.toggleAutoPaging() } label: {
                    toolbarIcon(vm.isAutoPaging ? "pause.circle.fill" : "play.circle", vm.isAutoPaging ? "暂停" : "自动")
                }
                .disabled(vm.pageCount == 0)
                Spacer()
                Button { showSettings = true } label: {
                    toolbarIcon("gearshape", "设置")
                }
            }
            .padding(.horizontal, 8)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .modifier(ReaderBarBackground(edge: .bottom))
    }

    private func toolbarIcon(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.title3).accessibilityHidden(true)
            Text(title).font(.caption2)
        }
        .frame(minWidth: 52, minHeight: 44)
        .contentShape(Rectangle())
    }

    /// 页码滑块。右→左阅读时反向（对应 `ReversibleSeekBar`），拖动时显示页码气泡，松手跳转
    private var sliderRow: some View {
        let count = vm.pageCount
        let shown = dragPage.map { Int($0.rounded()) } ?? vm.currentPage
        return HStack(spacing: 10) {
            Text("\(shown + 1)")
                .font(.footnote.monospacedDigit())
                .frame(minWidth: 32)
                .accessibilityHidden(true)
            Slider(
                value: Binding(
                    get: { dragPage ?? Double(vm.currentPage) },
                    set: { value in
                        // 拖动时只更新气泡，松手跳转；VoiceOver / 键盘调整没有拖动过程，直接跳页
                        if isDragging {
                            dragPage = value
                        } else {
                            vm.jump(to: Int(value.rounded()))
                        }
                    }
                ),
                in: 0...Double(max(count - 1, 1)),
                step: 1
            ) { editing in
                isDragging = editing
                if editing {
                    if dragPage == nil { dragPage = Double(vm.currentPage) }
                } else if let target = dragPage {
                    vm.jump(to: Int(target.rounded()))
                    dragPage = nil
                }
            }
            .accessibilityLabel("页码")
            .accessibilityValue("第 \(shown + 1) 页，共 \(count) 页")
            Text("\(count)")
                .font(.footnote.monospacedDigit())
                .frame(minWidth: 32)
                .accessibilityHidden(true)
        }
        .environment(\.layoutDirection, config.isRTL ? .rightToLeft : .leftToRight)
    }
}

/// 拖动滑块时的页码气泡（已加载的页显示缩略图）
private struct ReaderPageBubble: View {
    let vm: ReaderViewModel
    let page: Int
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(spacing: 6) {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 110, maxHeight: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Text("\(page + 1) / \(vm.pageCount)")
                .font(.headline.monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .task(id: page) {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            let image = await vm.thumbnail(for: page)
            guard !Task.isCancelled else { return }
            thumbnail = image
        }
    }
}

/// 时钟 / 进度 / 电量角标。对应 Android `GalleryHeader`（clock / progress / battery）
private struct ReaderStatusBadge: View {
    let config: ReaderConfig
    let page: Int
    let count: Int

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 8) {
                if config.showProgress {
                    Text("\(page + 1)/\(count)")
                }
                if config.showClock {
                    Text(context.date, format: .dateTime.hour().minute())
                }
                if config.showBattery {
                    battery
                }
            }
            .font(.caption2.monospacedDigit().weight(.medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.black.opacity(0.45), in: Capsule())
        }
    }

    @ViewBuilder
    private var battery: some View {
        let device = UIDevice.current
        let level = device.batteryLevel
        if level >= 0 {
            let charging = device.batteryState == .charging || device.batteryState == .full
            HStack(spacing: 2) {
                Image(systemName: charging ? "battery.100.bolt" : Self.symbol(for: level))
                Text("\(Int((level * 100).rounded()))%")
            }
        }
    }

    private static func symbol(for level: Float) -> String {
        switch level {
        case ..<0.13: return "battery.0"
        case ..<0.38: return "battery.25"
        case ..<0.63: return "battery.50"
        case ..<0.88: return "battery.75"
        default: return "battery.100"
        }
    }
}

// MARK: - 工具栏背景

/// iOS 26 起使用 Liquid Glass，之前为材质背景
private struct ReaderBarBackground: ViewModifier {
    let edge: Edge.Set

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(.horizontal, 8)
                .padding(edge == .top ? .top : .bottom, 4)
        } else {
            content.background(.ultraThinMaterial, ignoresSafeAreaEdges: edge)
        }
    }
}

// MARK: - 点按区域引导

/// 首次进入阅读器时显示的点按区域说明，点任意处关闭。对应 Android `guideGallery`
private struct ReaderTapGuide: View {
    let direction: EhSettings.ReadingDirection
    let dismiss: () -> Void

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Group {
                if direction == .topToBottom {
                    VStack(spacing: 0) {
                        zone("上一屏", systemImage: "arrow.up", tint: .blue)
                            .frame(height: size.height * 0.3)
                        zone("显示 / 隐藏工具栏", systemImage: "menubar.rectangle", tint: .gray, extra: true)
                        zone("下一屏", systemImage: "arrow.down", tint: .green)
                            .frame(height: size.height * 0.3)
                    }
                } else {
                    let rtl = direction == .rightToLeft
                    HStack(spacing: 0) {
                        zone(rtl ? "下一页" : "上一页", systemImage: "arrow.left", tint: rtl ? .green : .blue)
                            .frame(width: size.width * 0.3)
                        zone("显示 / 隐藏工具栏", systemImage: "menubar.rectangle", tint: .gray, extra: true)
                        zone(rtl ? "上一页" : "下一页", systemImage: "arrow.right", tint: rtl ? .blue : .green)
                            .frame(width: size.width * 0.3)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(perform: dismiss)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("轻点关闭引导")
    }

    private func zone(_ title: String, systemImage: String, tint: Color, extra: Bool = false) -> some View {
        ZStack {
            tint.opacity(0.35)
            VStack(spacing: 10) {
                Image(systemName: systemImage).font(.title)
                Text(title).font(.headline).multilineTextAlignment(.center)
                if extra {
                    VStack(spacing: 4) {
                        Text("双击缩放 · 长按页面查看更多操作")
                        Text("向下轻扫关闭阅读器")
                        Text("轻点任意处开始阅读").fontWeight(.semibold).padding(.top, 8)
                    }
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                }
            }
            .foregroundStyle(.white)
            .padding(12)
        }
        .overlay { Rectangle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5) }
    }
}
