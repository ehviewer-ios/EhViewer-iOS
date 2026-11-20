import SwiftUI
import NukeUI
import Nuke
import EhCore

/// 画廊封面缩略图
struct ThumbnailImage: View {
    let url: String?
    var referer: String?
    var contentMode: ContentMode = .fill

    var body: some View {
        LazyImage(request: ImageRequest.eh(url, referer: referer)) { state in
            if let image = state.image {
                image.resizable().aspectRatio(contentMode: contentMode)
            } else if state.error != nil {
                placeholder(systemName: "photo.badge.exclamationmark")
            } else {
                placeholder(systemName: "photo")
            }
        }
        .clipped()
    }

    private func placeholder(systemName: String) -> some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: systemName).foregroundStyle(.secondary)
        }
    }
}

/// 预览缩略图（雪碧图自动裁剪）
struct PreviewThumbnail: View {
    let preview: GalleryPreview
    var referer: String?

    var body: some View {
        let processors: [any ImageProcessing] = preview.clip.map {
            [SpriteCropProcessor(x: $0.x, y: $0.y, width: $0.width, height: $0.height)]
        } ?? []
        LazyImage(request: ImageRequest.eh(preview.imageUrl, referer: referer, processors: processors)) { state in
            if let image = state.image {
                image.resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(.quaternary)
                    .aspectRatio(aspect, contentMode: .fit)
                    .overlay { if state.error != nil { Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary) } }
            }
        }
    }

    private var aspect: CGFloat {
        if let c = preview.clip, c.height > 0 { return CGFloat(c.width) / CGFloat(c.height) }
        return 0.7
    }
}
