import SwiftUI
import EhCore
import EhStorage

/// 画廊单元共享样式。对应 Android `GalleryAdapter` 中的颜色/尺寸常量
enum GalleryCellStyle {
    /// 封面宽高比（宽 / 高），与站点缩略图大致一致
    static let coverAspect: CGFloat = 0.7

    /// 收藏夹 0-9 的颜色（与站点一致）；-1 为本地收藏
    static func favoriteColor(slot: Int) -> Color {
        let table: [(Double, Double, Double)] = [
            (0, 0, 0), (240, 0, 0), (240, 160, 0), (208, 208, 0), (0, 128, 0),
            (144, 240, 64), (64, 176, 240), (0, 0, 240), (80, 0, 128), (224, 128, 224),
        ]
        guard table.indices.contains(slot) else { return .pink }
        // 0 号收藏夹为黑色，在深色模式下不可见，改用主前景色
        if slot == 0 { return Color.primary }
        let c = table[slot]
        let light = UIColor(red: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: 1)
        // 深色模式下把过暗的颜色（7 蓝、8 紫等）提亮
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        light.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let dark = UIColor(hue: h, saturation: max(s - 0.25, 0.35), brightness: max(b, 1.0), alpha: 1)
        return Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    /// 是否已收藏（-1 本地，0..9 云端）
    static func isFavorited(_ info: GalleryInfo) -> Bool { info.favoriteSlot >= -1 }

    /// 页数 + 语言等简短元信息，如 "ZH · 24P"
    static func metaText(_ info: GalleryInfo) -> String {
        var parts: [String] = []
        if let lang = info.simpleLanguage, !lang.isEmpty { parts.append(lang) }
        if info.pages > 0 { parts.append("\(info.pages)P") }
        return parts.joined(separator: " · ")
    }
}

/// 收藏标记（心形，颜色对应收藏夹）
struct GalleryFavoriteMark: View {
    let info: GalleryInfo
    var size: CGFloat = 11
    @ScaledMetric(relativeTo: .caption) private var scale: CGFloat = 1

    var body: some View {
        if GalleryCellStyle.isFavorited(info) {
            Image(systemName: info.favoriteSlot == -1 ? "heart.circle.fill" : "heart.fill")
                .font(.system(size: size * scale))
                .foregroundStyle(GalleryCellStyle.favoriteColor(slot: info.favoriteSlot))
                .accessibilityLabel(Text(info.favoriteName ?? "已收藏"))
        }
    }
}

/// 下载状态小图标（state 取 `DownloadInfo.state*`，来自 `model.downloadState(gid:)`）
struct GalleryDownloadBadge: View {
    let state: Int

    var body: some View {
        Image(systemName: symbol)
            .font(.caption)
            .foregroundStyle(color)
            .accessibilityLabel(Text(label))
    }

    private var symbol: String {
        switch state {
        case DownloadInfo.stateFinish: return "arrow.down.circle.fill"
        case DownloadInfo.stateDownload: return "arrow.down.circle.dotted"
        case DownloadInfo.stateFailed: return "exclamationmark.circle"
        case DownloadInfo.stateWait: return "clock.arrow.circlepath"
        default: return "arrow.down.circle"
        }
    }

    private var color: Color {
        switch state {
        case DownloadInfo.stateFinish: return .green
        case DownloadInfo.stateFailed: return .red
        default: return .accentColor
        }
    }

    private var label: String {
        switch state {
        case DownloadInfo.stateFinish: return "已下载"
        case DownloadInfo.stateDownload: return "下载中"
        case DownloadInfo.stateFailed: return "下载失败"
        case DownloadInfo.stateWait: return "等待下载"
        default: return "在下载列表中"
        }
    }
}

/// 画廊列表行：封面、标题、上传者、评分、分类、语言/页数、发布时间、收藏标记。
/// 对应 Android `GalleryAdapter`（详情模式 list item）。
/// `accessory` 为附加信息插槽（如下载进度条、阅读进度、历史时间），显示在行底部。
struct GalleryRow<Accessory: View>: View {
    @Environment(AppModel.self) private var model

    let info: GalleryInfo
    /// 封面宽度
    var thumbWidth: CGFloat
    private let accessory: Accessory

    init(info: GalleryInfo, thumbWidth: CGFloat = 84, @ViewBuilder accessory: () -> Accessory) {
        self.info = info
        self.thumbWidth = thumbWidth
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ThumbnailImage(url: info.thumb, referer: model.site.referer)
                .frame(width: thumbWidth, height: thumbWidth / GalleryCellStyle.coverAspect)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(model.title(of: info))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(3)
                    .foregroundStyle(.primary)

                if let uploader = info.uploader, !uploader.isEmpty {
                    Text(uploader)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .strikethrough(info.disowned)
                        .lineLimit(1)
                }

                Spacer(minLength: 2)

                HStack(spacing: 6) {
                    RatingView(rating: info.rating, size: 11, color: info.rated ? .blue : .orange, userRated: info.rated)
                    Spacer(minLength: 4)
                    let meta = GalleryCellStyle.metaText(info)
                    if !meta.isEmpty {
                        Text(meta).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 6) {
                    CategoryBadge(category: info.category, compact: true)
                    Spacer(minLength: 4)
                    GalleryFavoriteMark(info: info, size: 10)
                    if let posted = info.posted {
                        Text(posted).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }

                accessory
            }
            .frame(maxWidth: .infinity, minHeight: thumbWidth / GalleryCellStyle.coverAspect, alignment: .topLeading)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

extension GalleryRow where Accessory == EmptyView {
    init(info: GalleryInfo, thumbWidth: CGFloat = 84) {
        self.init(info: info, thumbWidth: thumbWidth) { EmptyView() }
    }
}
