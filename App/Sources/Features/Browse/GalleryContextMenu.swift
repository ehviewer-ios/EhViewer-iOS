import SwiftUI
import UIKit
import EhCore
import EhNetwork
import EhStorage

/// 画廊的收藏操作（列表长按菜单使用）。对应 Android `CommonOperations.addToFavorites / removeFromFavorites`
@MainActor
enum BrowseGalleryActions {
    /// 加入收藏：slot -1 为本地收藏，0..9 为云端收藏夹。成功返回 true。
    /// 成功时界面上的收藏标记会变化，因此只给触感、不弹提示；失败才提示
    static func addFavorite(_ info: GalleryInfo, slot: Int, model: AppModel) async -> Bool {
        do {
            if slot == -1 {
                try model.database.putLocalFavorite(info)
            } else {
                try await model.api.addFavorites(gid: info.gid, token: info.token, dstCat: slot)
            }
            Haptics.success()
            return true
        } catch {
            model.toast.show("收藏失败：\(error.localizedDescription)", systemImage: "exclamationmark.circle")
            return false
        }
    }

    /// 取消收藏（按当前所在位置）
    static func removeFavorite(_ info: GalleryInfo, model: AppModel) async -> Bool {
        do {
            if info.favoriteSlot == -1 {
                try model.database.removeLocalFavorites(gid: info.gid)
            } else {
                try await model.api.addFavorites(gid: info.gid, token: info.token, dstCat: -1)
            }
            Haptics.success()
            return true
        } catch {
            model.toast.show("取消收藏失败：\(error.localizedDescription)", systemImage: "exclamationmark.circle")
            return false
        }
    }

    static func favoriteName(_ slot: Int, model: AppModel) -> String {
        if slot == -1 { return "本地收藏" }
        let names = model.setting(\.favCat)
        return names.indices.contains(slot) ? names[slot] : "Favorites \(slot)"
    }

    static func galleryURL(_ info: GalleryInfo, site: EhSite) -> URL? {
        URL(string: EhURL.galleryDetail(site, gid: info.gid, token: info.token))
    }
}

/// 画廊长按菜单内容：阅读、下载、收藏、复制链接/标题、分享、按上传者搜索。
/// 对应 Android `GalleryListScene.onItemLongClick`。收藏/历史等页面也可复用。
struct GalleryContextMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.navigate) private var navigate
    let info: GalleryInfo
    /// 收藏状态变化（新的 favoriteSlot 与收藏夹名）
    var onFavoriteChanged: (Int, String?) -> Void = { _, _ in }

    var body: some View {
        Button {
            model.openReader(info)
        } label: {
            Label("阅读", systemImage: "book")
        }

        if model.downloadState(gid: info.gid) != nil {
            Button {
                model.showDownloads()
            } label: {
                Label("在下载中查看", systemImage: "arrow.down.circle.fill")
            }
        } else {
            Button {
                model.startDownload(info)
            } label: {
                Label("下载", systemImage: "arrow.down.circle")
            }
        }

        favoriteMenu

        Divider()

        if let url = BrowseGalleryActions.galleryURL(info, site: model.site) {
            Button {
                UIPasteboard.general.string = url.absoluteString
                model.toast.show("链接已复制", systemImage: "doc.on.doc")
            } label: {
                Label("复制链接", systemImage: "link")
            }
            ShareLink(item: url, subject: Text(model.title(of: info))) {
                Label("分享", systemImage: "square.and.arrow.up")
            }
        }
        Button {
            UIPasteboard.general.string = model.title(of: info)
            model.toast.show("标题已复制", systemImage: "doc.on.doc")
        } label: {
            Label("复制标题", systemImage: "textformat")
        }

        if let uploader = info.uploader, !uploader.isEmpty {
            Divider()
            Button {
                navigate(.list(.uploader(uploader), title: uploader))
            } label: {
                Label("搜索上传者：\(uploader)", systemImage: "person")
            }
        }
    }

    @ViewBuilder
    private var favoriteMenu: some View {
        if GalleryCellStyle.isFavorited(info) {
            // 可逆操作：不标红（菜单中唯一的红色项留给真正的删除）
            Button {
                Task {
                    if await BrowseGalleryActions.removeFavorite(info, model: model) {
                        onFavoriteChanged(-2, nil)
                    }
                }
            } label: {
                Label {
                    Text("取消收藏")
                    Text(info.favoriteName ?? BrowseGalleryActions.favoriteName(info.favoriteSlot, model: model))
                } icon: {
                    Image(systemName: "heart.slash")
                }
            }
        } else {
            Menu {
                Button {
                    add(slot: -1)
                } label: {
                    Label("本地收藏", systemImage: "iphone")
                }
                if model.isSignedIn {
                    let names = model.setting(\.favCat)
                    ForEach(0..<10, id: \.self) { slot in
                        Button {
                            add(slot: slot)
                        } label: {
                            Label(names.indices.contains(slot) ? names[slot] : "Favorites \(slot)", systemImage: "heart")
                        }
                    }
                }
            } label: {
                Label("收藏", systemImage: "heart")
            }
        }
    }

    private func add(slot: Int) {
        Task {
            if await BrowseGalleryActions.addFavorite(info, slot: slot, model: model) {
                onFavoriteChanged(slot, BrowseGalleryActions.favoriteName(slot, model: model))
            }
        }
    }
}

/// 长按预览：大封面 + 标题
struct GalleryContextPreview: View {
    @Environment(AppModel.self) private var model
    let info: GalleryInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ThumbnailImage(url: info.thumb, referer: model.site.referer, contentMode: .fit)
                .frame(width: 280, height: 280 / GalleryCellStyle.coverAspect)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title(of: info)).font(.headline).lineLimit(3)
                HStack {
                    CategoryBadge(category: info.category)
                    RatingView(rating: info.rating)
                    Spacer()
                    Text(GalleryCellStyle.metaText(info)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding([.horizontal, .bottom], 12)
        }
        .frame(width: 280)
        .background(Color(uiColor: .systemBackground))
    }
}
