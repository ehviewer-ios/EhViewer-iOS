import UIKit

/// 纵向连续滚动（条漫）布局。对应 Android glgallery `ScrollLayoutManager`。
///
/// 每页宽度 = 视口宽 × zoom，高度按图片宽高比（未知时用默认比例）。整体缩放时所有坐标线性放大，
/// 因此缩放 / 尺寸更新时可以精确保持锚点。
final class ReaderVerticalLayout: UICollectionViewLayout {
    /// 页数
    var itemCount = 0
    /// 整体缩放（1 = 适应宽度）
    var zoom: CGFloat = 1
    /// 页间距（zoom = 1 时）
    var gap: CGFloat = 0
    /// 高 / 宽；nil 表示尚未知
    var aspectProvider: ((Int) -> CGFloat?)?
    /// 未知尺寸时的默认高宽比（常见漫画页 ≈ 1.42）
    var defaultAspect: CGFloat = 1.42

    private var frames: [CGRect] = []
    private var contentSize: CGSize = .zero
    private var preparedWidth: CGFloat = -1

    override func prepare() {
        super.prepare()
        recompute()
    }

    /// 重新计算所有页的位置
    func recompute() {
        guard let cv = collectionView else { return }
        let width = cv.bounds.width * zoom
        preparedWidth = cv.bounds.width
        let spacing = gap * zoom
        var y: CGFloat = 0
        frames.removeAll(keepingCapacity: true)
        frames.reserveCapacity(itemCount)
        for i in 0..<itemCount {
            let aspect = aspectProvider?(i) ?? defaultAspect
            let h = max((width * aspect).rounded(), 1)
            frames.append(CGRect(x: 0, y: y, width: width, height: h))
            y += h
            if i < itemCount - 1 { y += spacing }
        }
        contentSize = CGSize(width: width, height: y)
    }

    override var collectionViewContentSize: CGSize { contentSize }

    func frame(forItem item: Int) -> CGRect {
        guard item >= 0, item < frames.count else { return .zero }
        return frames[item]
    }

    /// y 处（内容坐标）的页；落在间距里时取下一页
    func item(atY y: CGFloat) -> Int {
        guard !frames.isEmpty else { return 0 }
        var lo = 0, hi = frames.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if frames[mid].maxY <= y { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard !frames.isEmpty else { return [] }
        var result: [UICollectionViewLayoutAttributes] = []
        var i = item(atY: rect.minY)
        while i < frames.count, frames[i].minY <= rect.maxY {
            if frames[i].intersects(rect) {
                let a = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: i, section: 0))
                a.frame = frames[i]
                result.append(a)
            }
            i += 1
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.item < frames.count else { return nil }
        let a = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        a.frame = frames[indexPath.item]
        return a
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != preparedWidth
    }
}
