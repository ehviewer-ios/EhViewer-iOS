import Foundation
import EhCore

/// 外部打开链接：ehviewer://、站点链接、从“文件”App 打开的 zip
extension AppModel {
    func handleOpenURL(_ url: URL) {
        if url.isFileURL {
            openExternalFile(url)
            return
        }
        var target = url.absoluteString
        if url.scheme?.lowercased() == "ehviewer" {
            // ehviewer://open?url=<站点链接>、ehviewer://g/<gid>/<token>
            if let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value {
                target = q
            } else if url.host == "g" {
                let parts = url.pathComponents.filter { $0 != "/" }
                if parts.count >= 2, let gid = Int64(parts[0]) {
                    router.pendingRoute = .galleryToken(gid: gid, token: parts[1])
                }
                return
            } else {
                return
            }
        }
        switch EhUrlRoute.parseEhUrl(target) {
        case let .galleryList(builder)?:
            router.pendingRoute = .list(builder, title: nil)
        case let .galleryDetail(gid, token)?:
            router.pendingRoute = .galleryToken(gid: gid, token: token)
        case let .galleryPage(gid, pToken, page)?:
            Task {
                do {
                    let token = try await api.getGalleryToken(gid: gid, gtoken: pToken, page: page)
                    router.pendingRoute = .galleryToken(gid: gid, token: token)
                } catch {
                    toast.error(error)
                }
            }
        default:
            toast.show("无法识别的链接", systemImage: "link")
        }
    }

    /// 从“文件”App 打开的归档：复制到临时目录后直接阅读
    private func openExternalFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard ["zip", "cbz"].contains(ext) else {
            toast.show("不支持的文件类型：\(ext)", systemImage: "doc")
            return
        }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let dest = (directories.tempDir ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(UUID().uuidString + "." + ext)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            openReader(ReaderRequest(source: .archive(dest, title: url.deletingPathExtension().lastPathComponent)))
        } catch {
            toast.error(error)
        }
    }
}
