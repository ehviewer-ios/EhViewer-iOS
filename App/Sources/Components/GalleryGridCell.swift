import SwiftUI
import EhCore

/// 画廊网格单元：固定比例封面（分类、收藏、语言/页数叠加在封面上）+ 标题 + 评分。
/// 对应 Android `GalleryAdapter`（缩略图模式 grid item）。
/// 放在 `LazyVGrid(columns: [GridItem(.adaptive(minimum: GalleryCellStyle.gridMinimumWidth(for:)))])` 中自适应多列。
/// `accessory` 为封面底部的叠加插槽（如下载进度条）。
struct GalleryGridCell<Accessory: View>: View {
    @Environment(AppModel.self) private var model

    let info: GalleryInfo
    var showsTitle: Bool
    private let accessory: Accessory

    init(info: GalleryInfo, showsTitle: Bool = true, @ViewBuilder accessory: () -> Accessory) {
        self.info = info
        self.showsTitle = showsTitle
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(GalleryCellStyle.coverAspect, contentMode: .fit)
                .overlay { ThumbnailImage(url: info.thumb, referer: model.site.referer) }
                .overlay(alignment: .topLeading) {
                    CategoryBadge(category: info.category, compact: true).padding(4)
                }
                .overlay(alignment: .topTrailing) {
                    if GalleryCellStyle.isFavorited(info) {
                        GalleryFavoriteMark(info: info, size: 11)
                            .padding(4)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(4)
                    }
                }
                .overlay(alignment: .bottom) {
                    VStack(spacing: 0) {
                        HStack {
                            Spacer()
                            let meta = GalleryCellStyle.metaText(info)
                            if !meta.isEmpty {
                                Text(meta)
                                    .font(.caption2.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(.black.opacity(0.55), in: Capsule())
                                    .padding(4)
                            }
                        }
                        accessory
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            if showsTitle {
                Text(model.title(of: info))
                    .font(.caption)
                    .lineLimit(2, reservesSpace: true)
                    .foregroundStyle(.primary)
                RatingView(rating: info.rating, size: 10, color: info.rated ? .blue : .orange, userRated: info.rated)
            }
        }
        .contentShape(Rectangle())
    }
}

extension GalleryGridCell where Accessory == EmptyView {
    init(info: GalleryInfo, showsTitle: Bool = true) {
        self.init(info: info, showsTitle: showsTitle) { EmptyView() }
    }
}

extension GalleryCellStyle {
    /// 根据缩略图尺寸设置（`EhSettings.thumbSize`：0 大 / 1 中 / 2 小）给出网格最小列宽
    static func gridMinimumWidth(for thumbSize: Int) -> CGFloat {
        switch thumbSize {
        case 0: return 150
        case 2: return 92
        default: return 115
        }
    }
}
