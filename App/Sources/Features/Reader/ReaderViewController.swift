import UIKit
import EhSpider
import EhStorage

/// 阅读器主视图（UIKit）。对应 Android `GalleryView` + `PagerLayoutManager` / `ScrollLayoutManager`。
///
/// - 左→右 / 右→左：水平分页 `UICollectionView`（右→左通过反转 item 与页的映射实现）
/// - 上→下：纵向连续滚动（`ReaderVerticalLayout`），支持整体捏合缩放
/// - 手势：轻点中间切换工具栏、边缘翻页（翻页模式左右、条漫模式上下）、中间双击缩放、长按页面菜单（上下文菜单）、
///   下滑关闭；键盘方向键 / 空格；音量键（可选）；VoiceOver 三指滑动翻页、双指 Z 字关闭
final class ReaderViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate,
    UICollectionViewDataSourcePrefetching, UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate {

    private let viewModel: ReaderViewModel
    private var config: ReaderConfig
    private var collectionView: UICollectionView?
    private var verticalLayout: ReaderVerticalLayout?
    private let decoder = ReaderImageDecoder()

    /// 页 → 原图像素尺寸（条漫布局用）
    private var pixelSizes: [Int: CGSize] = [:]
    private var sizeLoading: Set<Int> = []
    private var pendingSizeUpdate = false
    /// 布局完成后要跳转到的页
    private var pendingJump: Int?
    private var lastViewSize: CGSize = .zero
    private var isTransitioning = false
    /// 「固定比例」缩放值（相对原始像素）
    private var fixedZoom: CGFloat = 1

    /// 中间区域单击（需等待双击失败）
    private let singleTap = UITapGestureRecognizer()
    /// 边缘区域单击（立即翻页，不等待双击）
    private let edgeTap = UITapGestureRecognizer()
    private let doubleTap = UITapGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()
    /// 下滑关闭
    private let dismissPan = UIPanGestureRecognizer()
    /// 下滑关闭期间被临时停用的滚动手势
    private var suspendedPans: [UIGestureRecognizer] = []
    private var pinchStartZoom: CGFloat = 1
    private var pinchAnchor: CGPoint = .zero

    private var volumeObserver: ReaderVolumeKeyObserver?

    init(viewModel: ReaderViewModel, config: ReaderConfig) {
        self.viewModel = viewModel
        self.config = config
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var isVertical: Bool { config.direction == .topToBottom }
    private var isRTL: Bool { config.direction == .rightToLeft }
    private var pageCount: Int { viewModel.pageCount }
    private var pagerGap: CGFloat { config.showPageInterval ? 48 : 0 }
    private var stripGap: CGFloat { config.showPageInterval ? 28 : 0 }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        // 黑色背景由 SwiftUI 外壳提供（下滑关闭时渐隐）
        view.backgroundColor = .clear
        view.clipsToBounds = true
        viewModel.controller = self

        singleTap.addTarget(self, action: #selector(handleSingleTap(_:)))
        edgeTap.addTarget(self, action: #selector(handleSingleTap(_:)))
        doubleTap.addTarget(self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)
        pinch.addTarget(self, action: #selector(handlePinch(_:)))
        dismissPan.addTarget(self, action: #selector(handleDismissPan(_:)))
        dismissPan.maximumNumberOfTouches = 1
        for g in [singleTap, edgeTap, doubleTap, pinch, dismissPan] as [UIGestureRecognizer] {
            g.delegate = self
            view.addGestureRecognizer(g)
        }
        buildCollectionView()
        applyVolumeSetting()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        applyVolumeSetting()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        volumeObserver?.detach()
        volumeObserver = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let cv = collectionView else { return }
        let size = view.bounds.size
        if size != lastViewSize {
            if lastViewSize != .zero, pendingJump == nil { pendingJump = viewModel.currentPage }
            lastViewSize = size
        }
        let frame = collectionFrame()
        if cv.frame != frame { cv.frame = frame }
        if let flow = cv.collectionViewLayout as? UICollectionViewFlowLayout, flow.itemSize != frame.size, frame.width > 0 {
            flow.itemSize = frame.size
            flow.invalidateLayout()
        }
        if let target = pendingJump, frame.width > 0, frame.height > 0 {
            cv.layoutIfNeeded()
            scrollToPage(target, animated: false)
            pendingJump = nil
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        isTransitioning = true
        pendingJump = viewModel.currentPage
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self else { return }
            self.isTransitioning = false
            self.scrollToPage(self.viewModel.currentPage, animated: false)
        }
    }

    private func collectionFrame() -> CGRect {
        let b = view.bounds
        return isVertical ? b : CGRect(x: 0, y: 0, width: b.width + pagerGap, height: b.height)
    }

    // MARK: - 构建 / 配置

    private func buildCollectionView() {
        collectionView?.removeFromSuperview()
        pixelSizes.removeAll()
        sizeLoading.removeAll()

        let layout: UICollectionViewLayout
        if isVertical {
            let l = ReaderVerticalLayout()
            l.itemCount = pageCount
            l.gap = stripGap
            l.aspectProvider = { [weak self] item in
                guard let size = self?.pixelSizes[item], size.width > 0 else { return nil }
                return size.height / size.width
            }
            verticalLayout = l
            layout = l
        } else {
            let l = UICollectionViewFlowLayout()
            l.scrollDirection = .horizontal
            l.minimumLineSpacing = 0
            l.minimumInteritemSpacing = 0
            l.itemSize = collectionFrame().size
            verticalLayout = nil
            layout = l
        }
        let cv = UICollectionView(frame: collectionFrame(), collectionViewLayout: layout)
        cv.backgroundColor = .clear
        cv.isPagingEnabled = !isVertical
        cv.showsHorizontalScrollIndicator = false
        cv.showsVerticalScrollIndicator = false
        cv.contentInsetAdjustmentBehavior = .never
        cv.scrollsToTop = false
        cv.alwaysBounceVertical = isVertical
        cv.alwaysBounceHorizontal = !isVertical
        cv.decelerationRate = isVertical ? .normal : .fast
        cv.register(ReaderPagerCell.self, forCellWithReuseIdentifier: ReaderPagerCell.reuseID)
        cv.register(ReaderStripCell.self, forCellWithReuseIdentifier: ReaderStripCell.reuseID)
        cv.dataSource = self
        cv.delegate = self
        cv.prefetchDataSource = self
        view.insertSubview(cv, at: 0)
        collectionView = cv
        pinch.isEnabled = isVertical
        pendingJump = viewModel.currentPage
        view.setNeedsLayout()
    }

    /// 设置变化（来自 SwiftUI）
    func apply(_ newConfig: ReaderConfig) {
        let old = config
        config = newConfig
        guard isViewLoaded else { return }
        if old.direction != newConfig.direction || old.showPageInterval != newConfig.showPageInterval {
            buildCollectionView()
        } else if old.scaling != newConfig.scaling || old.startPosition != newConfig.startPosition {
            for cell in collectionView?.visibleCells ?? [] {
                (cell as? ReaderPagerCell)?.apply(options: pagerOptions)
            }
        }
        if old.volumePage != newConfig.volumePage { applyVolumeSetting() }
    }

    private var pagerOptions: ReaderPagerCell.Options {
        ReaderPagerCell.Options(scaling: config.scaling, startPosition: config.startPosition,
                                fixedZoom: config.scaling == .fixed ? fixedZoom : 1,
                                gap: pagerGap, policy: pagePolicy)
    }

    /// 翻页模式解码上限：屏幕长边像素 × 1.5（缩放后仍清晰）
    private var pagePolicy: ReaderImageDecoder.Policy {
        let scale = max(traitCollection.displayScale, 1)
        let long = max(view.bounds.width, view.bounds.height, 320) * scale * 1.5
        return .page(maxDimension: Int(min(max(long, 2048), 6144)))
    }

    /// 条漫模式解码宽度：屏幕宽像素 × 1.5
    private var stripPolicy: ReaderImageDecoder.Policy {
        let scale = max(traitCollection.displayScale, 1)
        let w = max(view.bounds.width, 320) * scale * 1.5
        return .strip(width: Int(min(max(w, 1024), 3072)))
    }

    private func applyVolumeSetting() {
        if config.volumePage, view.window != nil {
            if volumeObserver == nil {
                let o = ReaderVolumeKeyObserver()
                o.onVolumeUp = { [weak self] in self?.volumeKey(up: true) }
                o.onVolumeDown = { [weak self] in self?.volumeKey(up: false) }
                o.attach(to: view)
                volumeObserver = o
            }
        } else {
            volumeObserver?.detach()
            volumeObserver = nil
        }
    }

    /// 音量上 = 上一页，音量下 = 下一页；「反转音量键」交换
    private func volumeKey(up: Bool) {
        let previous = up != config.reverseVolumePage
        if previous { turnPrevious(animated: true) } else { turnNext(animated: true) }
    }

    // MARK: - 页 / item 映射

    private func page(forItem item: Int) -> Int { isRTL ? pageCount - 1 - item : item }
    private func item(forPage page: Int) -> Int { isRTL ? pageCount - 1 - page : page }

    // MARK: - 来自 ViewModel

    func reloadPages() {
        guard isViewLoaded, let cv = collectionView else { return }
        verticalLayout?.itemCount = pageCount
        cv.reloadData()
        pendingJump = viewModel.currentPage
        view.setNeedsLayout()
    }

    func pageStateChanged(_ page: Int) {
        guard isViewLoaded, let cv = collectionView, page >= 0, page < pageCount else { return }
        let state = viewModel.state(of: page)
        if isVertical, case let .loaded(url) = state, pixelSizes[page] == nil {
            loadPixelSize(page: page, url: url)
        }
        let indexPath = IndexPath(item: item(forPage: page), section: 0)
        if let cell = cv.cellForItem(at: indexPath) as? ReaderPageCell, cell.page == page {
            cell.update(state: state)
        }
    }

    // MARK: - 条漫尺寸

    private func loadPixelSize(page: Int, url: URL) {
        guard !sizeLoading.contains(page) else { return }
        sizeLoading.insert(page)
        Task { [weak self] in
            let size = await Task.detached(priority: .userInitiated) { ReaderImageDecoder.pixelSize(of: url) }.value
            guard let self else { return }
            self.sizeLoading.remove(page)
            guard let size, self.isVertical else { return }
            self.pixelSizes[page] = size
            self.scheduleSizeUpdate()
        }
    }

    /// 合并同一轮的尺寸更新
    private func scheduleSizeUpdate() {
        guard !pendingSizeUpdate else { return }
        pendingSizeUpdate = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingSizeUpdate = false
            self.relayoutVertical(keepingAnchor: true)
        }
    }

    /// 重新布局条漫，保持视口顶部内容不跳动
    private func relayoutVertical(keepingAnchor: Bool) {
        guard let cv = collectionView, let layout = verticalLayout else { return }
        let y = cv.contentOffset.y
        let anchor = layout.item(atY: y)
        let oldFrame = layout.frame(forItem: anchor)
        let ratio = oldFrame.height > 0 ? (y - oldFrame.minY) / oldFrame.height : 0
        layout.invalidateLayout()
        layout.recompute()
        cv.layoutIfNeeded()
        guard keepingAnchor, pendingJump == nil else { return }
        let newFrame = layout.frame(forItem: anchor)
        let maxY = max(0, layout.collectionViewContentSize.height - cv.bounds.height)
        let newY = min(max(newFrame.minY + ratio * newFrame.height, 0), maxY)
        if abs(newY - cv.contentOffset.y) > 0.5 {
            cv.contentOffset = CGPoint(x: cv.contentOffset.x, y: newY)
        }
    }

    // MARK: - 翻页 / 跳转

    func scrollToPage(_ page: Int, animated: Bool) {
        guard let cv = collectionView, pageCount > 0 else { return }
        let page = min(max(page, 0), pageCount - 1)
        if isVertical {
            guard let layout = verticalLayout else { return }
            if layout.frame(forItem: page) == .zero { layout.recompute() }
            let maxY = max(0, layout.collectionViewContentSize.height - cv.bounds.height)
            let y = min(max(layout.frame(forItem: page).minY, 0), maxY)
            cv.setContentOffset(CGPoint(x: cv.contentOffset.x, y: y), animated: animated)
        } else {
            let x = CGFloat(item(forPage: page)) * cv.bounds.width
            cv.setContentOffset(CGPoint(x: x, y: 0), animated: animated)
        }
    }

    /// 物理方向向左（对应 `pageLeft`）。纵向模式为向上一屏
    @discardableResult
    func pageLeft(animated: Bool) -> Bool {
        if isVertical { return scrollScreen(-1, animated: animated) }
        return scrollToItem(currentItem - 1, animated: animated)
    }

    /// 物理方向向右（对应 `pageRight`）。纵向模式为向下一屏
    @discardableResult
    func pageRight(animated: Bool) -> Bool {
        if isVertical { return scrollScreen(1, animated: animated) }
        return scrollToItem(currentItem + 1, animated: animated)
    }

    /// 下一页（按阅读方向）。返回是否翻页成功
    @discardableResult
    func turnNext(animated: Bool) -> Bool {
        isRTL ? pageLeft(animated: animated) : pageRight(animated: animated)
    }

    @discardableResult
    func turnPrevious(animated: Bool) -> Bool {
        isRTL ? pageRight(animated: animated) : pageLeft(animated: animated)
    }

    private var currentItem: Int { item(forPage: viewModel.currentPage) }

    private func scrollToItem(_ item: Int, animated: Bool) -> Bool {
        guard let cv = collectionView, item >= 0, item < pageCount else { return false }
        cv.setContentOffset(CGPoint(x: CGFloat(item) * cv.bounds.width, y: 0), animated: animated)
        if !animated { updateCurrentPage() }
        return true
    }

    private func scrollScreen(_ direction: CGFloat, animated: Bool) -> Bool {
        guard let cv = collectionView else { return false }
        let maxY = max(0, cv.contentSize.height - cv.bounds.height)
        let target = min(max(cv.contentOffset.y + direction * cv.bounds.height * 0.9, 0), maxY)
        guard abs(target - cv.contentOffset.y) > 1 else { return false }
        cv.setContentOffset(CGPoint(x: cv.contentOffset.x, y: target), animated: animated)
        return true
    }

    private func updateCurrentPage() {
        guard let cv = collectionView, pageCount > 0, pendingJump == nil, !isTransitioning else { return }
        let page: Int
        if isVertical {
            guard let layout = verticalLayout else { return }
            let maxY = max(0, cv.contentSize.height - cv.bounds.height)
            if cv.contentOffset.y >= maxY - 1, maxY > 0 {
                // 滚到底：最后一个可见页
                page = layout.item(atY: cv.contentOffset.y + cv.bounds.height - 1)
            } else {
                page = layout.item(atY: cv.contentOffset.y + cv.bounds.height * 0.4)
            }
        } else {
            let w = cv.bounds.width
            guard w > 0 else { return }
            let item = min(max(Int((cv.contentOffset.x / w).rounded()), 0), pageCount - 1)
            page = self.page(forItem: item)
        }
        viewModel.currentPageChanged(min(max(page, 0), pageCount - 1))
    }

    // MARK: - UICollectionViewDataSource / Delegate

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        pageCount
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let page = page(forItem: indexPath.item)
        let state = viewModel.state(of: page)
        if isVertical {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ReaderStripCell.reuseID, for: indexPath) as! ReaderStripCell
            cell.configure(page: page, state: state, policy: stripPolicy, decoder: decoder)
            cell.onRetry = { [weak self] p in self?.viewModel.retry(p) }
            prepareCommon(cell, page: page)
            return cell
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ReaderPagerCell.reuseID, for: indexPath) as! ReaderPagerCell
        cell.configure(page: page, state: state, options: pagerOptions, decoder: decoder)
        cell.onRetry = { [weak self] p in self?.viewModel.retry(p) }
        cell.onUserZoom = { [weak self] scale in self?.fixedZoom = scale }
        prepareCommon(cell, page: page)
        return cell
    }

    /// 读屏信息、上下文菜单
    private func prepareCommon(_ cell: ReaderPageCell, page: Int) {
        cell.totalPages = pageCount
        cell.pageActions = accessibilityPageActions(page)
        cell.accessibilityScrollHandler = { [weak self] direction in
            self?.accessibilityScroll(direction) ?? false
        }
        if !cell.interactions.contains(where: { $0 is UIContextMenuInteraction }) {
            cell.addInteraction(UIContextMenuInteraction(delegate: self))
        }
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        let page = page(forItem: indexPath.item)
        viewModel.pageNeeded(page)
        let state = viewModel.state(of: page)
        if isVertical, case let .loaded(url) = state, pixelSizes[page] == nil {
            loadPixelSize(page: page, url: url)
        }
        if let pager = cell as? ReaderPagerCell {
            pager.apply(options: pagerOptions)
        }
        (cell as? ReaderPageCell)?.willDisplay(state: state)
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? ReaderPageCell)?.didEndDisplay()
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            let page = page(forItem: indexPath.item)
            viewModel.pageNeeded(page)
            if case let .loaded(url) = viewModel.state(of: page) {
                decoder.prefetch(url, policy: isVertical ? stripPolicy : pagePolicy)
                if isVertical, pixelSizes[page] == nil { loadPixelSize(page: page, url: url) }
            }
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === collectionView else { return }
        updateCurrentPage()
    }

    // MARK: - 手势

    /// 点按区域
    enum TapZone { case previous, next, menu }

    /// 翻页模式：左 30% / 右 30%（物理方向，左=pageLeft）；条漫模式：上 30% 上一屏 / 下 30% 下一屏；其余为工具栏区域
    static func tapZone(at point: CGPoint, in size: CGSize, vertical: Bool) -> TapZone {
        if vertical {
            if point.y < size.height * 0.3 { return .previous }
            if point.y > size.height * 0.7 { return .next }
            return .menu
        }
        if point.x < size.width * 0.3 { return .previous }
        if point.x > size.width * 0.7 { return .next }
        return .menu
    }

    /// 当前翻页模式 cell
    private var currentPagerCell: ReaderPagerCell? {
        guard !isVertical, let cv = collectionView, pageCount > 0 else { return nil }
        return cv.cellForItem(at: IndexPath(item: currentItem, section: 0)) as? ReaderPagerCell
    }

    /// 页面已放大（此时边缘点按不翻页，所有点按都按中间区域处理）
    private var isZoomedIn: Bool {
        if isVertical { return (verticalLayout?.zoom ?? 1) > 1.01 }
        return currentPagerCell?.isZoomedIn ?? false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if touch.view is UIControl { return false }
        guard gestureRecognizer === singleTap || gestureRecognizer === edgeTap || gestureRecognizer === doubleTap else {
            return true
        }
        // 边缘区域的点按交给 edgeTap（不等待双击），中间区域交给 singleTap / doubleTap
        let onEdge = !isZoomedIn && !viewModel.showChrome
            && Self.tapZone(at: touch.location(in: view), in: view.bounds.size, vertical: isVertical) != .menu
        return gestureRecognizer === edgeTap ? onEdge : !onEdge
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dismissPan else { return true }
        return shouldBeginDismissPan()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // 条漫捏合与滚动可同时进行
        if gestureRecognizer === pinch { return other === collectionView?.panGestureRecognizer }
        // 下滑关闭与滚动手势同时识别，开始后停用滚动手势
        if gestureRecognizer === dismissPan { return other is UIPanGestureRecognizer }
        return false
    }

    /// 轻点：边缘翻页，中间切换工具栏（对应 GalleryView 的 left / right / menu 区域）
    @objc private func handleSingleTap(_ g: UITapGestureRecognizer) {
        if viewModel.showChrome || isZoomedIn {
            viewModel.toggleChrome()
            return
        }
        switch Self.tapZone(at: g.location(in: view), in: view.bounds.size, vertical: isVertical) {
        case .previous: pageLeft(animated: true)
        case .next: pageRight(animated: true)
        case .menu: viewModel.toggleChrome()
        }
    }

    // MARK: 下滑关闭

    private func shouldBeginDismissPan() -> Bool {
        guard let cv = collectionView, pageCount > 0 else { return false }
        let v = dismissPan.velocity(in: view)
        // 只接受明显向下的拖动
        guard v.y > 0, v.y > abs(v.x) * 1.5 else { return false }
        if isVertical {
            guard (verticalLayout?.zoom ?? 1) <= 1.01 else { return false }
            return cv.contentOffset.y <= 0.5
        }
        guard !cv.isDecelerating, let cell = currentPagerCell else { return false }
        return cell.allowsDismissPan
    }

    @objc private func handleDismissPan(_ g: UIPanGestureRecognizer) {
        guard let cv = collectionView else { return }
        let t = g.translation(in: view)
        let height = max(view.bounds.height, 1)
        switch g.state {
        case .began:
            // 取消正在进行的滚动 / 页内拖动，避免同时移动
            var pans: [UIGestureRecognizer] = [cv.panGestureRecognizer]
            if let cell = currentPagerCell { pans.append(cell.zoomPanGesture) }
            for p in pans where p.isEnabled {
                p.isEnabled = false
                suspendedPans.append(p)
            }
        case .changed:
            let progress = min(max(t.y / (height * 0.5), 0), 1)
            let scale = 1 - 0.25 * progress
            cv.transform = CGAffineTransform(translationX: t.x * 0.5, y: max(t.y, 0)).scaledBy(x: scale, y: scale)
            viewModel.dismissProgress = Double(progress)
        case .ended, .cancelled, .failed:
            for p in suspendedPans { p.isEnabled = true }
            suspendedPans.removeAll()
            let velocity = g.velocity(in: view).y
            if g.state == .ended, t.y > 120 || (t.y > 40 && velocity > 900) {
                viewModel.requestClose()
                return
            }
            let reset = {
                cv.transform = .identity
                self.viewModel.dismissProgress = 0
            }
            if UIAccessibility.isReduceMotionEnabled {
                UIView.animate(withDuration: 0.2, animations: reset)
            } else {
                UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0,
                               options: [.allowUserInteraction], animations: reset)
            }
            if !isVertical { scrollToPage(viewModel.currentPage, animated: true) }
        default:
            break
        }
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        guard let cv = collectionView else { return }
        if isVertical {
            toggleVerticalZoom(at: g.location(in: cv))
            return
        }
        let point = g.location(in: cv)
        guard let indexPath = cv.indexPathForItem(at: point),
              let cell = cv.cellForItem(at: indexPath) as? ReaderPagerCell else { return }
        cell.toggleZoom(at: cv.convert(point, to: cell))
    }

    // MARK: - 页面上下文菜单（对应 Android `showPageDialog`）

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let cell = interaction.view as? ReaderPageCell, cell.page >= 0 else { return nil }
        let page = cell.page
        // 分享弹出框锚点：长按位置（窗口坐标）
        let anchor = cell.convert(CGRect(origin: location, size: CGSize(width: 1, height: 1)), to: nil)
        let image = cell.displayedImage
        let canPlay = cell.canPlayAnimation
        let bounds = view.bounds.size
        return UIContextMenuConfiguration(identifier: nil, previewProvider: {
            image.map { ReaderMenuPreviewController(image: $0, maxSize: bounds) }
        }, actionProvider: { [weak self, weak cell] _ in
            guard let self else { return nil }
            var children: [UIMenuElement] = []
            if canPlay {
                children.append(UIAction(title: "播放动图", image: UIImage(systemName: "play.circle")) { _ in
                    cell?.playAnimation()
                })
            }
            children.append(UIMenu(title: "", options: .displayInline, children: self.pageMenuActions(page, anchor: anchor)))
            return UIMenu(title: "第 \(page + 1) 页", children: children)
        })
    }

    /// 页面操作（与工具栏“更多”菜单一致）
    private func pageMenuActions(_ page: Int, anchor: CGRect?) -> [UIMenuElement] {
        let vm = viewModel
        return [
            UIAction(title: "分享", image: UIImage(systemName: "square.and.arrow.up")) { _ in vm.share(page, sourceRect: anchor) },
            UIAction(title: "保存到相册", image: UIImage(systemName: "square.and.arrow.down")) { _ in vm.saveToPhotos(page) },
            UIAction(title: "复制图片", image: UIImage(systemName: "doc.on.doc")) { _ in vm.copyImage(page) },
            UIAction(title: "刷新本页", image: UIImage(systemName: "arrow.clockwise")) { _ in vm.refresh(page) },
        ]
    }

    /// 读屏自定义操作（与上下文菜单一致）
    private func accessibilityPageActions(_ page: Int) -> [UIAccessibilityCustomAction] {
        let vm = viewModel
        weak var anchorView = view
        func anchor() -> CGRect? {
            guard let v = anchorView else { return nil }
            return v.convert(CGRect(x: v.bounds.midX, y: v.bounds.midY, width: 1, height: 1), to: nil)
        }
        return [
            UIAccessibilityCustomAction(name: "分享") { _ in vm.share(page, sourceRect: anchor()); return true },
            UIAccessibilityCustomAction(name: "保存到相册") { _ in vm.saveToPhotos(page); return true },
            UIAccessibilityCustomAction(name: "复制图片") { _ in vm.copyImage(page); return true },
            UIAccessibilityCustomAction(name: "刷新本页") { _ in vm.refresh(page); return true },
        ]
    }

    // MARK: - VoiceOver

    /// 三指滑动翻页，翻页后播报页码
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard pageCount > 0 else { return false }
        let moved: Bool
        switch direction {
        case .left: moved = pageRight(animated: false)
        case .right: moved = pageLeft(animated: false)
        case .up, .next: moved = isVertical ? scrollScreen(1, animated: false) : turnNext(animated: false)
        case .down, .previous: moved = isVertical ? scrollScreen(-1, animated: false) : turnPrevious(animated: false)
        @unknown default: moved = false
        }
        guard moved else { return false }
        updateCurrentPage()
        collectionView?.layoutIfNeeded()
        UIAccessibility.post(notification: .pageScrolled,
                             argument: "第 \(viewModel.currentPage + 1) / \(pageCount) 页")
        return true
    }

    /// 双指 Z 字手势：关闭阅读器
    override func accessibilityPerformEscape() -> Bool {
        viewModel.requestClose()
        return true
    }

    /// 条漫整体缩放：所有坐标随 zoom 线性变化，按手指位置保持锚点
    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard isVertical, let cv = collectionView, let layout = verticalLayout else { return }
        let loc = g.location(in: cv)
        let locInView = CGPoint(x: loc.x - cv.contentOffset.x, y: loc.y - cv.contentOffset.y)
        switch g.state {
        case .began:
            // 捏合期间停用滚动手势，避免两者同时修改 contentOffset
            cv.panGestureRecognizer.isEnabled = false
            pinchStartZoom = layout.zoom
            pinchAnchor = CGPoint(x: loc.x / layout.zoom, y: loc.y / layout.zoom)
        case .changed:
            let zoom = min(max(pinchStartZoom * g.scale, 1), 4)
            setVerticalZoom(zoom, anchor: pinchAnchor, locationInView: locInView)
        case .ended, .cancelled, .failed:
            cv.panGestureRecognizer.isEnabled = true
            updateCurrentPage()
        default:
            break
        }
    }

    private func setVerticalZoom(_ zoom: CGFloat, anchor: CGPoint, locationInView: CGPoint) {
        guard let cv = collectionView, let layout = verticalLayout else { return }
        layout.zoom = zoom
        layout.invalidateLayout()
        layout.recompute()
        cv.layoutIfNeeded()
        let content = layout.collectionViewContentSize
        let maxX = max(0, content.width - cv.bounds.width)
        let maxY = max(0, content.height - cv.bounds.height)
        let x = min(max(anchor.x * zoom - locationInView.x, 0), maxX)
        let y = min(max(anchor.y * zoom - locationInView.y, 0), maxY)
        cv.contentOffset = CGPoint(x: x, y: y)
    }

    private func toggleVerticalZoom(at point: CGPoint) {
        guard let cv = collectionView, let layout = verticalLayout else { return }
        let locInView = CGPoint(x: point.x - cv.contentOffset.x, y: point.y - cv.contentOffset.y)
        let anchor = CGPoint(x: point.x / layout.zoom, y: point.y / layout.zoom)
        let target: CGFloat = layout.zoom > 1.01 ? 1 : 2
        UIView.animate(withDuration: 0.25) {
            self.setVerticalZoom(target, anchor: anchor, locationInView: locInView)
        }
    }

    // MARK: - 键盘

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let defs: [(String, UIKeyModifierFlags, Selector, String)] = [
            (UIKeyCommand.inputLeftArrow, [], #selector(keyLeft), "向左翻页"),
            (UIKeyCommand.inputRightArrow, [], #selector(keyRight), "向右翻页"),
            (UIKeyCommand.inputUpArrow, [], #selector(keyPrevious), "上一页"),
            (UIKeyCommand.inputDownArrow, [], #selector(keyNext), "下一页"),
            (UIKeyCommand.inputPageUp, [], #selector(keyPrevious), "上一页"),
            (UIKeyCommand.inputPageDown, [], #selector(keyNext), "下一页"),
            (" ", [], #selector(keyNext), "下一页"),
            (" ", .shift, #selector(keyPrevious), "上一页"),
            ("\r", [], #selector(keyMenu), "显示 / 隐藏工具栏"),
        ]
        return defs.map { input, modifiers, action, title in
            let c = UIKeyCommand(input: input, modifierFlags: modifiers, action: action)
            c.discoverabilityTitle = title
            c.wantsPriorityOverSystemBehavior = true
            return c
        }
    }

    @objc private func keyLeft() { pageLeft(animated: true) }
    @objc private func keyRight() { pageRight(animated: true) }
    @objc private func keyNext() { turnNext(animated: true) }
    @objc private func keyPrevious() { turnPrevious(animated: true) }
    @objc private func keyMenu() { viewModel.toggleChrome() }

    // MARK: - 分享

    /// sourceRect：触发位置（窗口坐标）；nil 时以视图中心为锚点
    func presentShareSheet(for url: URL, sourceRect: CGRect?) {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = vc.popoverPresentationController {
            pop.sourceView = view
            if let sourceRect, !sourceRect.isNull {
                pop.sourceRect = view.convert(sourceRect, from: nil)
            } else {
                pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            }
        }
        // 从最上层的已展示控制器弹出（菜单 / sheet 可能正在显示）
        var presenter: UIViewController = self
        while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
        presenter.present(vc, animated: true)
    }
}

// MARK: - 长按菜单预览

/// 上下文菜单的图片预览（按图片比例）
final class ReaderMenuPreviewController: UIViewController {
    private let image: UIImage
    private let maxSize: CGSize

    init(image: UIImage, maxSize: CGSize) {
        self.image = image
        self.maxSize = maxSize
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = view.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(imageView)
        view.backgroundColor = .black
        let size = image.size
        if size.width > 0, size.height > 0 {
            let scale = min(maxSize.width * 0.9 / size.width, maxSize.height * 0.6 / size.height, 1)
            preferredContentSize = CGSize(width: size.width * scale, height: size.height * scale)
        }
    }
}
