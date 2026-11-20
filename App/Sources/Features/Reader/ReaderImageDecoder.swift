import UIKit
import ImageIO
import UniformTypeIdentifiers

/// 解码后的页图片
final class ReaderDecodedImage {
    /// 降采样后的位图（静态图或动图第一帧）
    let image: UIImage
    /// 原图像素尺寸（已应用 EXIF 方向）
    let pixelSize: CGSize
    /// 是否为多帧动图（GIF / APNG / 动态 WebP）
    let isAnimated: Bool
    /// 内存占用（字节），用于 NSCache 计费
    let cost: Int

    init(image: UIImage, pixelSize: CGSize, isAnimated: Bool, cost: Int) {
        self.image = image
        self.pixelSize = pixelSize
        self.isAnimated = isAnimated
        self.cost = cost
    }
}

/// 阅读器图片解码器：ImageIO 降采样，后台队列解码，带内存缓存。
/// 对应 Android glgallery 中 `ImageWrapper` / `GalleryProvider` 的解码部分（Android 用 Image 原生解码 + 纹理分块）。
@MainActor
final class ReaderImageDecoder {
    /// 解码尺寸策略
    enum Policy: Hashable {
        /// 翻页模式：长边不超过 maxDimension 像素
        case page(maxDimension: Int)
        /// 条漫模式：宽度不超过 width 像素（长图不按长边缩小，避免变糊）
        case strip(width: Int)
    }

    /// 单张位图像素上限（约 96MB RGBA），防止超大图撑爆内存
    nonisolated static let maxPixelArea: CGFloat = 24_000_000

    /// NSCache 本身线程安全
    private final class Cache: @unchecked Sendable {
        let storage = NSCache<NSString, ReaderDecodedImage>()
        func get(_ key: String) -> ReaderDecodedImage? { storage.object(forKey: key as NSString) }
        func set(_ value: ReaderDecodedImage, _ key: String) { storage.setObject(value, forKey: key as NSString, cost: value.cost) }
    }

    private let cache = Cache()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "ehviewer.reader.decode"
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()
    private var prefetching: Set<String> = []
    private var memoryObserver: NSObjectProtocol?

    init() {
        cache.storage.totalCostLimit = 160 * 1024 * 1024
        cache.storage.countLimit = 12
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.purge() }
        }
    }

    deinit {
        queue.cancelAllOperations()
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
    }

    /// 清空缓存（屏幕上的 cell 自己持有图片，不受影响）
    func purge() {
        cache.storage.removeAllObjects()
        prefetching.removeAll()
    }

    private static func key(_ url: URL, _ policy: Policy) -> String {
        switch policy {
        case let .page(d): return "\(url.path)|p\(d)"
        case let .strip(w): return "\(url.path)|s\(w)"
        }
    }

    func cached(_ url: URL, policy: Policy) -> ReaderDecodedImage? {
        cache.get(Self.key(url, policy))
    }

    /// 后台解码。返回的 Operation 可取消；被取消（未开始执行）时不回调
    @discardableResult
    func decode(_ url: URL, policy: Policy, priority: Operation.QueuePriority = .normal,
                completion: @escaping @MainActor (ReaderDecodedImage?) -> Void) -> Operation {
        let key = Self.key(url, policy)
        let cache = self.cache
        let op = BlockOperation()
        op.queuePriority = priority
        op.addExecutionBlock { [weak op] in
            guard let op, !op.isCancelled else { return }
            let result: ReaderDecodedImage?
            if let hit = cache.get(key) {
                result = hit
            } else {
                result = Self.decodeImage(at: url, policy: policy)
                if let result { cache.set(result, key) }
            }
            Task { @MainActor in completion(result) }
        }
        queue.addOperation(op)
        return op
    }

    /// 预解码到缓存（低优先级）
    func prefetch(_ url: URL, policy: Policy) {
        let key = Self.key(url, policy)
        guard cache.get(key) == nil, !prefetching.contains(key) else { return }
        prefetching.insert(key)
        decode(url, policy: policy, priority: .low) { [weak self] _ in
            self?.prefetching.remove(key)
        }
    }

    // MARK: - ImageIO

    /// 读取图片像素尺寸（只读文件头，很快）
    nonisolated static func pixelSize(of url: URL) -> CGSize? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts) else { return nil }
        return pixelSize(of: src)
    }

    nonisolated private static func pixelSize(of src: CGImageSource) -> CGSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        guard w > 0, h > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    nonisolated static func decodeImage(at url: URL, policy: Policy) -> ReaderDecodedImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts), CGImageSourceGetCount(src) > 0 else { return nil }
        let frameCount = CGImageSourceGetCount(src)
        let size = pixelSize(of: src)

        var maxPixel: CGFloat = 4096
        if let size {
            let longSide = max(size.width, size.height)
            var scale: CGFloat
            switch policy {
            case let .page(d): scale = min(1, CGFloat(d) / longSide)
            case let .strip(w): scale = min(1, CGFloat(w) / size.width)
            }
            let area = size.width * size.height * scale * scale
            if area > maxPixelArea { scale = sqrt(maxPixelArea / (size.width * size.height)) }
            maxPixel = max(1, (longSide * scale).rounded(.up))
        }

        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        let pixel = size ?? CGSize(width: cg.width, height: cg.height)
        // 调试：-EHDisableImages YES 时以同尺寸的占位图代替真实内容（用于截图/自动化测试）
        if UserDefaults.standard.bool(forKey: "EHDisableImages") {
            return ReaderDecodedImage(image: placeholder(width: cg.width, height: cg.height, url: url), pixelSize: pixel,
                                      isAnimated: false, cost: cg.bytesPerRow * cg.height)
        }
        return ReaderDecodedImage(image: UIImage(cgImage: cg), pixelSize: pixel,
                                  isAnimated: frameCount > 1, cost: cg.bytesPerRow * cg.height)
    }

    nonisolated private static func placeholder(width: Int, height: Int, url: URL) -> UIImage {
        let size = CGSize(width: max(width, 1), height: max(height, 1))
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.systemTeal.withAlphaComponent(0.35).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let text = "\(url.lastPathComponent)\n\(width)×\(height)" as NSString
            text.draw(at: CGPoint(x: 20, y: 20),
                      withAttributes: [.font: UIFont.systemFont(ofSize: max(size.width / 18, 14)), .foregroundColor: UIColor.label])
        }
    }

    /// 小缩略图（滑块气泡用）
    nonisolated static func thumbnail(at url: URL, maxPixel: CGFloat) -> UIImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts) else { return nil }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else { return nil }
        if UserDefaults.standard.bool(forKey: "EHDisableImages") { return nil }
        return UIImage(cgImage: cg)
    }

    /// 根据文件内容判断图片类型（下载 / 缓存文件可能没有扩展名）
    nonisolated static func imageType(of url: URL) -> UTType? {
        if !url.pathExtension.isEmpty, let t = UTType(filenameExtension: url.pathExtension), t.conforms(to: .image) {
            return t
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let id = CGImageSourceGetType(src) as String? else { return nil }
        return UTType(id)
    }
}

/// 单个 cell 的图片加载槽：负责解码请求的发起 / 取消，以及动图播放。cell 复用时取消
@MainActor
final class ReaderImageSlot {
    private(set) var url: URL?
    private(set) var decoded: ReaderDecodedImage?
    private var operation: Operation?
    private var animationToken = 0
    private(set) var isAnimating = false

    var hasImage: Bool { decoded != nil }
    var isAnimatedImage: Bool { decoded?.isAnimated ?? false }

    /// 加载图片。同一 URL 已加载 / 加载中时不重复请求
    func load(_ url: URL, policy: ReaderImageDecoder.Policy, decoder: ReaderImageDecoder,
              onImage: @escaping @MainActor (ReaderDecodedImage) -> Void,
              onFailure: @escaping @MainActor () -> Void) {
        if self.url == url, decoded != nil || operation != nil { return }
        cancel()
        self.url = url
        if let hit = decoder.cached(url, policy: policy) {
            decoded = hit
            onImage(hit)
            return
        }
        operation = decoder.decode(url, policy: policy) { [weak self] result in
            guard let self, self.url == url else { return }
            self.operation = nil
            if let result {
                self.decoded = result
                onImage(result)
            } else {
                onFailure()
            }
        }
    }

    /// 取消解码并释放图片
    func cancel() {
        operation?.cancel()
        operation = nil
        stopAnimation()
        url = nil
        decoded = nil
    }

    /// 播放动图（逐帧由 ImageIO 解码，内存占用小）。
    /// 系统关闭“自动播放动态图像”时只显示首帧，除非用户手动播放（force）
    func startAnimation(in imageView: UIImageView, force: Bool = false) {
        guard let decoded, decoded.isAnimated, let url, !isAnimating else { return }
        guard force || UIAccessibility.isVideoAutoplayEnabled else { return }
        animationToken &+= 1
        let token = animationToken
        isAnimating = true
        let status = CGAnimateImageAtURLWithBlock(url as CFURL, nil) { [weak self, weak imageView] _, cgImage, stop in
            MainActor.assumeIsolated {
                guard let self, let imageView, self.animationToken == token else {
                    stop.pointee = true
                    return
                }
                imageView.image = UIImage(cgImage: cgImage)
            }
        }
        if status != noErr { isAnimating = false }
    }

    func stopAnimation() {
        animationToken &+= 1
        isAnimating = false
    }
}
