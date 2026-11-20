import UIKit
import EhSpider
import EhStorage

/// 阅读器 cell 公共接口
@MainActor
protocol ReaderPageCell: UICollectionViewCell {
    var page: Int { get }
    /// 页状态变化
    func update(state: PageState)
    /// 将要显示（重新加载被释放的图片、恢复动图）
    func willDisplay(state: PageState)
    /// 离开屏幕：取消解码、释放位图（缓存里仍可能有）
    func didEndDisplay()
    /// 总页数（读屏标签用）
    var totalPages: Int { get set }
    /// 页面操作（读屏自定义操作；重试由 cell 自己添加）
    var pageActions: [UIAccessibilityCustomAction] { get set }
    /// 读屏三指滑动翻页
    var accessibilityScrollHandler: ((UIAccessibilityScrollDirection) -> Bool)? { get set }
    /// 当前显示的图片（长按菜单预览用）
    var displayedImage: UIImage? { get }
    /// 当前图片是否为动图且未在播放（“自动播放动态图像”关闭时可手动播放）
    var canPlayAnimation: Bool { get }
    func playAnimation()
}

/// cell 读屏信息：作为一个图片元素，标签为“第 n / N 页”，加载中 / 失败时附带状态
@MainActor
enum ReaderCellAccessibility {
    static func apply(to cell: UICollectionViewCell, page: Int, total: Int, status: ReaderPageStatusView,
                      actions: [UIAccessibilityCustomAction], onRetry: @escaping () -> Void) {
        cell.isAccessibilityElement = true
        cell.accessibilityTraits = .image
        var label = total > 0 ? "第 \(page + 1) / \(total) 页" : "第 \(page + 1) 页"
        if !status.isHidden, let text = status.statusDescription { label += "，" + text }
        cell.accessibilityLabel = label
        var all: [UIAccessibilityCustomAction] = []
        if !status.isHidden, status.isShowingError {
            all.append(UIAccessibilityCustomAction(name: "重试") { _ in onRetry(); return true })
        }
        all += actions
        cell.accessibilityCustomActions = all
    }
}

// MARK: - 状态视图（页码 / 进度 / 错误）

/// 加载中显示页码与进度环，失败显示错误与重试按钮。对应 Android `GalleryPageView` 的 info / progress / error
final class ReaderPageStatusView: UIView {
    private let numberLabel = UILabel()
    private let ring = ReaderProgressRing()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let errorLabel = UILabel()
    private let retryButton = UIButton(configuration: .bordered())
    private let stack = UIStackView()
    var onRetry: (() -> Void)?
    /// 读屏用状态描述（加载中 / 失败原因）；图片已就绪时为 nil
    private(set) var statusDescription: String?
    private(set) var isShowingError = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        numberLabel.font = UIFontMetrics(forTextStyle: .largeTitle)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: 40, weight: .semibold))
        numberLabel.adjustsFontForContentSizeCategory = true
        numberLabel.textColor = UIColor(white: 1, alpha: 0.55)
        numberLabel.textAlignment = .center

        spinner.color = UIColor(white: 1, alpha: 0.7)
        spinner.hidesWhenStopped = true

        errorLabel.font = .preferredFont(forTextStyle: .subheadline)
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center

        var config = UIButton.Configuration.bordered()
        config.title = "重试"
        config.image = UIImage(systemName: "arrow.clockwise")
        config.imagePadding = 6
        config.baseForegroundColor = .white
        retryButton.configuration = config
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .primaryActionTriggered)

        let ringBox = UIView()
        ringBox.translatesAutoresizingMaskIntoConstraints = false
        ring.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        ringBox.addSubview(ring)
        ringBox.addSubview(spinner)
        NSLayoutConstraint.activate([
            ringBox.widthAnchor.constraint(equalToConstant: 44),
            ringBox.heightAnchor.constraint(equalToConstant: 44),
            ring.leadingAnchor.constraint(equalTo: ringBox.leadingAnchor),
            ring.trailingAnchor.constraint(equalTo: ringBox.trailingAnchor),
            ring.topAnchor.constraint(equalTo: ringBox.topAnchor),
            ring.bottomAnchor.constraint(equalTo: ringBox.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: ringBox.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: ringBox.centerYAnchor),
        ])

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        [numberLabel, ringBox, errorLabel, retryButton].forEach(stack.addArrangedSubview)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
        ringBox.tag = 1
    }

    required init?(coder: NSCoder) { fatalError() }

    private var ringBox: UIView? { stack.arrangedSubviews.first { $0.tag == 1 } }

    /// 根据状态显示；`.loaded` 时（图片解码中）只显示页码
    func show(page: Int, state: PageState) {
        numberLabel.text = "\(page + 1)"
        isShowingError = false
        switch state {
        case .none:
            statusDescription = "正在加载"
            ringBox?.isHidden = false
            ring.isHidden = true
            spinner.startAnimating()
            errorLabel.isHidden = true
            retryButton.isHidden = true
        case let .loading(progress):
            ringBox?.isHidden = false
            statusDescription = progress.map { "正在加载 \(Int(($0 * 100).rounded()))%" } ?? "正在加载"
            if let progress {
                spinner.stopAnimating()
                ring.isHidden = false
                ring.progress = CGFloat(progress)
            } else {
                ring.isHidden = true
                spinner.startAnimating()
            }
            errorLabel.isHidden = true
            retryButton.isHidden = true
        case .loaded:
            statusDescription = "正在解码"
            ringBox?.isHidden = true
            spinner.stopAnimating()
            errorLabel.isHidden = true
            retryButton.isHidden = true
        case let .failed(message):
            ringBox?.isHidden = true
            spinner.stopAnimating()
            errorLabel.text = Self.readableError(message)
            statusDescription = "加载失败：" + Self.readableError(message).replacingOccurrences(of: "\n", with: "，")
            isShowingError = true
            errorLabel.isHidden = false
            retryButton.isHidden = false
        }
    }

    /// 解码失败（文件损坏 / 格式不支持）
    func showDecodeFailure(page: Int) {
        show(page: page, state: .failed("图片解码失败"))
    }

    static func readableError(_ message: String) -> String {
        if message == SpiderMessages.error509 {
            return "509：图片配额已用尽\n请稍后再试，或在网页上重置额度"
        }
        return message
    }
}

/// 进度环
final class ReaderProgressRing: UIView {
    private let track = CAShapeLayer()
    private let bar = CAShapeLayer()

    var progress: CGFloat = 0 {
        didSet { bar.strokeEnd = min(max(progress, 0), 1) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        for l in [track, bar] {
            l.fillColor = UIColor.clear.cgColor
            l.lineWidth = 3.5
            l.lineCap = .round
            layer.addSublayer(l)
        }
        track.strokeColor = UIColor(white: 1, alpha: 0.18).cgColor
        bar.strokeColor = tintColor.cgColor
        bar.strokeEnd = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        bar.strokeColor = tintColor.cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = track.lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = UIBezierPath(arcCenter: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2,
                                startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        bar.frame = bounds
        track.path = path.cgPath
        bar.path = path.cgPath
        CATransaction.commit()
    }
}

// MARK: - 翻页模式 cell（可缩放）

/// 翻页模式单页：`UIScrollView` 缩放，支持缩放模式与起始位置。对应 Android glgallery `ImageView` + `PagerLayoutManager`
final class ReaderPagerCell: UICollectionViewCell, ReaderPageCell, UIScrollViewDelegate {
    static let reuseID = "ReaderPagerCell"

    struct Options: Equatable {
        var scaling: EhSettings.PageScaling = .fit
        var startPosition: EhSettings.StartPosition = .topRight
        /// 固定比例（相对原始像素比例）
        var fixedZoom: CGFloat = 1
        /// 页右侧留白（页间距）
        var gap: CGFloat = 0
        var policy: ReaderImageDecoder.Policy = .page(maxDimension: 4096)
    }

    private let zoomView = UIScrollView()
    private let imageView = UIImageView()
    private let statusView = ReaderPageStatusView()
    private let slot = ReaderImageSlot()
    private weak var decoder: ReaderImageDecoder?
    private(set) var page = -1
    private var options = Options()
    private var state: PageState = .none
    /// 原始比例（1 像素 = 1 物理像素）下图片的点尺寸
    private var baseSize: CGSize = .zero
    private var initialZoom: CGFloat = 1
    private var fitZoom: CGFloat = 1
    private var lastAreaSize: CGSize = .zero
    private var isDisplayed = false

    var onRetry: ((Int) -> Void)?
    /// 用户缩放结束（用于“固定比例”记忆）
    var onUserZoom: ((CGFloat) -> Void)?
    var totalPages = 0 { didSet { if totalPages != oldValue { refreshAccessibility() } } }
    var pageActions: [UIAccessibilityCustomAction] = [] { didSet { refreshAccessibility() } }
    var accessibilityScrollHandler: ((UIAccessibilityScrollDirection) -> Bool)?
    var displayedImage: UIImage? { imageView.image }
    var canPlayAnimation: Bool { slot.isAnimatedImage && !slot.isAnimating }

    func playAnimation() { slot.startAnimation(in: imageView, force: true) }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        accessibilityScrollHandler?(direction) ?? super.accessibilityScroll(direction)
    }

    private func refreshAccessibility() {
        ReaderCellAccessibility.apply(to: self, page: page, total: totalPages, status: statusView,
                                      actions: pageActions) { [weak self] in
            guard let self else { return }
            self.onRetry?(self.page)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        zoomView.delegate = self
        zoomView.showsVerticalScrollIndicator = false
        zoomView.showsHorizontalScrollIndicator = false
        zoomView.contentInsetAdjustmentBehavior = .never
        zoomView.decelerationRate = .fast
        zoomView.bouncesZoom = true
        zoomView.scrollsToTop = false
        imageView.contentMode = .scaleToFill
        zoomView.addSubview(imageView)
        contentView.addSubview(zoomView)
        contentView.addSubview(statusView)
        statusView.onRetry = { [weak self] in
            guard let self else { return }
            self.onRetry?(self.page)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        releaseImage()
        page = -1
        onRetry = nil
        onUserZoom = nil
        pageActions = []
        accessibilityScrollHandler = nil
    }

    func configure(page: Int, state: PageState, options: Options, decoder: ReaderImageDecoder) {
        let optionsChanged = options != self.options
        if options.policy != self.options.policy || page != self.page { slot.cancel() }
        self.page = page
        self.decoder = decoder
        self.options = options
        if optionsChanged { setNeedsLayout() }
        update(state: state)
        if optionsChanged, slot.hasImage { applyInitialZoom() }
    }

    /// 缩放模式 / 起始位置 / 间距变化
    func apply(options: Options) {
        guard options != self.options else { return }
        let policyChanged = options.policy != self.options.policy
        self.options = options
        setNeedsLayout()
        layoutIfNeeded()
        if policyChanged, case let .loaded(url) = state {
            slot.cancel()
            loadImage(url)
        } else if slot.hasImage {
            applyInitialZoom()
        }
    }

    func update(state: PageState) {
        self.state = state
        statusView.show(page: page, state: state)
        if case let .loaded(url) = state {
            loadImage(url)
        } else if slot.hasImage || slot.url != nil {
            // 强制刷新：旧图片作废
            releaseImage()
        }
        refreshAccessibility()
    }

    func willDisplay(state: PageState) {
        isDisplayed = true
        update(state: state)
        if slot.hasImage { slot.startAnimation(in: imageView) }
    }

    func didEndDisplay() {
        isDisplayed = false
        releaseImage()
        statusView.show(page: page, state: state)
    }

    private func releaseImage() {
        slot.cancel()
        imageView.image = nil
        baseSize = .zero
        zoomView.minimumZoomScale = 1
        zoomView.maximumZoomScale = 1
        zoomView.zoomScale = 1
        zoomView.contentSize = .zero
        zoomView.contentInset = .zero
        statusView.isHidden = false
    }

    private func loadImage(_ url: URL) {
        guard let decoder else { return }
        let page = self.page
        slot.load(url, policy: options.policy, decoder: decoder, onImage: { [weak self] decoded in
            guard let self, self.page == page else { return }
            self.show(decoded)
        }, onFailure: { [weak self] in
            guard let self, self.page == page else { return }
            self.statusView.showDecodeFailure(page: page)
            self.refreshAccessibility()
        })
    }

    private func show(_ decoded: ReaderDecodedImage) {
        let scale = max(traitCollection.displayScale, 1)
        baseSize = CGSize(width: decoded.pixelSize.width / scale, height: decoded.pixelSize.height / scale)
        imageView.image = decoded.image
        statusView.isHidden = true
        applyInitialZoom()
        if isDisplayed { slot.startAnimation(in: imageView) }
        refreshAccessibility()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = CGRect(x: 0, y: 0, width: max(bounds.width - options.gap, 0), height: bounds.height)
        zoomView.frame = area
        statusView.frame = area
        if area.size != lastAreaSize {
            lastAreaSize = area.size
            if slot.hasImage { applyInitialZoom() }
        }
    }

    /// 按缩放模式与起始位置摆放图片（对应 `ImageView.setScaleOffset`）
    private func applyInitialZoom() {
        let bounds = zoomView.bounds.size
        guard baseSize.width > 0, baseSize.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        let fitW = bounds.width / baseSize.width
        let fitH = bounds.height / baseSize.height
        fitZoom = min(fitW, fitH)
        var zoom: CGFloat
        switch options.scaling {
        case .origin: zoom = 1
        case .fitWidth: zoom = fitW
        case .fitHeight: zoom = fitH
        case .fit: zoom = fitZoom
        case .fixed: zoom = options.fixedZoom
        }
        zoom = min(max(zoom, 0.1), 10)
        initialZoom = zoom

        zoomView.minimumZoomScale = 1
        zoomView.maximumZoomScale = 1
        zoomView.zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: baseSize)
        zoomView.contentSize = baseSize
        zoomView.minimumZoomScale = min(zoom, fitZoom)
        zoomView.maximumZoomScale = max(max(zoom, fitZoom) * 4, 1)
        zoomView.zoomScale = zoom
        updateInsets()

        let content = zoomView.contentSize
        let maxX = max(0, content.width - bounds.width)
        let maxY = max(0, content.height - bounds.height)
        let factor: (CGFloat, CGFloat)
        switch options.startPosition {
        case .topLeft: factor = (0, 0)
        case .topRight: factor = (1, 0)
        case .bottomLeft: factor = (0, 1)
        case .bottomRight: factor = (1, 1)
        case .center: factor = (0.5, 0.5)
        }
        let inset = zoomView.contentInset
        zoomView.contentOffset = CGPoint(x: -inset.left + factor.0 * maxX, y: -inset.top + factor.1 * maxY)
    }

    /// 图片小于视口时居中
    private func updateInsets() {
        let content = zoomView.contentSize
        let bounds = zoomView.bounds.size
        let dx = max(0, (bounds.width - content.width) / 2)
        let dy = max(0, (bounds.height - content.height) / 2)
        zoomView.contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    /// 双击：放大到点击处 / 还原
    func toggleZoom(at point: CGPoint) {
        guard slot.hasImage else { return }
        let current = zoomView.zoomScale
        if abs(current - initialZoom) > initialZoom * 0.01 {
            UIView.animate(withDuration: 0.25) { self.applyInitialZoom() }
            return
        }
        let target = min(max(initialZoom * 2.5, fitZoom * 2), zoomView.maximumZoomScale)
        guard target > current else { return }
        let p = imageView.convert(point, from: self)
        let w = zoomView.bounds.width / target
        let h = zoomView.bounds.height / target
        zoomView.zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
    }

    /// 当前是否放大（放大时不响应边缘翻页）
    var isZoomedIn: Bool { slot.hasImage && zoomView.zoomScale > initialZoom * 1.01 }

    /// 下滑关闭的前提：未放大，且页面内容已在顶部（适应宽度的长图向下拖动时优先回到顶部）
    var allowsDismissPan: Bool {
        !isZoomedIn && zoomView.contentOffset.y <= -zoomView.contentInset.top + 1
    }

    /// 页内滚动手势（下滑关闭开始时取消它）
    var zoomPanGesture: UIPanGestureRecognizer { zoomView.panGestureRecognizer }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { slot.hasImage ? imageView : nil }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateInsets()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        onUserZoom?(scale)
    }
}

// MARK: - 条漫模式 cell

/// 纵向连续滚动单页。cell 尺寸由布局按图片宽高比给出，整体缩放由布局处理
final class ReaderStripCell: UICollectionViewCell, ReaderPageCell {
    static let reuseID = "ReaderStripCell"

    private let imageView = UIImageView()
    private let statusView = ReaderPageStatusView()
    private let slot = ReaderImageSlot()
    private weak var decoder: ReaderImageDecoder?
    private(set) var page = -1
    private var state: PageState = .none
    private var policy: ReaderImageDecoder.Policy = .strip(width: 2048)
    private var isDisplayed = false

    var onRetry: ((Int) -> Void)?
    var totalPages = 0 { didSet { if totalPages != oldValue { refreshAccessibility() } } }
    var pageActions: [UIAccessibilityCustomAction] = [] { didSet { refreshAccessibility() } }
    var accessibilityScrollHandler: ((UIAccessibilityScrollDirection) -> Bool)?
    var displayedImage: UIImage? { imageView.image }
    var canPlayAnimation: Bool { slot.isAnimatedImage && !slot.isAnimating }

    func playAnimation() { slot.startAnimation(in: imageView, force: true) }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        accessibilityScrollHandler?(direction) ?? super.accessibilityScroll(direction)
    }

    private func refreshAccessibility() {
        ReaderCellAccessibility.apply(to: self, page: page, total: totalPages, status: statusView,
                                      actions: pageActions) { [weak self] in
            guard let self else { return }
            self.onRetry?(self.page)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        contentView.addSubview(imageView)
        contentView.addSubview(statusView)
        statusView.onRetry = { [weak self] in
            guard let self else { return }
            self.onRetry?(self.page)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = contentView.bounds
        statusView.frame = contentView.bounds
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        releaseImage()
        page = -1
        onRetry = nil
        pageActions = []
        accessibilityScrollHandler = nil
    }

    func configure(page: Int, state: PageState, policy: ReaderImageDecoder.Policy, decoder: ReaderImageDecoder) {
        if policy != self.policy { slot.cancel() }
        self.page = page
        self.policy = policy
        self.decoder = decoder
        update(state: state)
    }

    func update(state: PageState) {
        self.state = state
        statusView.show(page: page, state: state)
        if case let .loaded(url) = state {
            loadImage(url)
        } else if slot.hasImage || slot.url != nil {
            releaseImage()
        }
        refreshAccessibility()
    }

    func willDisplay(state: PageState) {
        isDisplayed = true
        update(state: state)
        if slot.hasImage { slot.startAnimation(in: imageView) }
    }

    func didEndDisplay() {
        isDisplayed = false
        releaseImage()
        statusView.show(page: page, state: state)
    }

    private func releaseImage() {
        slot.cancel()
        imageView.image = nil
        statusView.isHidden = false
    }

    private func loadImage(_ url: URL) {
        guard let decoder else { return }
        let page = self.page
        slot.load(url, policy: policy, decoder: decoder, onImage: { [weak self] decoded in
            guard let self, self.page == page else { return }
            self.imageView.image = decoded.image
            self.statusView.isHidden = true
            if self.isDisplayed { self.slot.startAnimation(in: self.imageView) }
            self.refreshAccessibility()
        }, onFailure: { [weak self] in
            guard let self, self.page == page else { return }
            self.statusView.showDecodeFailure(page: page)
            self.refreshAccessibility()
        })
    }
}
