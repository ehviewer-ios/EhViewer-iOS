import SwiftUI
import UniformTypeIdentifiers
import EhCore
import EhNetwork

/// 种子列表。对应 Android `TorrentDownloadController.showTorrentList`
struct TorrentListView: View {
    @Environment(AppModel.self) private var model
    let detail: GalleryDetail

    @State private var torrents: [TorrentInfo] = []
    @State private var isLoading = false
    @State private var error: Error?
    @State private var loaded = false
    @State private var showNoMagnetApp = false

    var body: some View {
        content
            .navigationTitle("种子")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await load() }
            .task { if !loaded { await load() } }
            .alert("无法打开磁力链接", isPresented: $showNoMagnetApp) {
                Button("好", role: .cancel) {}
            } message: {
                Text("没有可以打开磁力链接的应用。可以复制磁力链接，或分享 .torrent 文件到 BT 客户端。")
            }
    }

    @ViewBuilder
    private var content: some View {
        if torrents.isEmpty {
            if isLoading || !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ErrorStateView(error: error) { Task { await load() } }
            } else {
                EmptyStateView(title: "没有种子", systemImage: "arrow.down.doc")
            }
        } else {
            List {
                Section {
                    ForEach(torrents, id: \.url) { t in
                        Menu {
                            menuItems(t)
                        } label: {
                            row(t)
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("点击条目复制磁力链接或分享 .torrent 文件（分享时下载）到其他 BT 客户端。")
                }
            }
        }
    }

    private func row(_ t: TorrentInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.zipper")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(t.name)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                if !t.posted.isEmpty {
                    Label(t.posted, systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func menuItems(_ t: TorrentInfo) -> some View {
        if let magnet = Self.magnet(for: t) {
            Button { DetailClipboard.copy(magnet, model, message: "已复制磁力链接") } label: {
                Label("复制磁力链接", systemImage: "link")
            }
            Button {
                guard let url = URL(string: magnet) else { return }
                UIApplication.shared.open(url) { ok in
                    if !ok { showNoMagnetApp = true }
                }
            } label: {
                Label("用其他应用打开磁力链接", systemImage: "arrow.up.forward.app")
            }
        }
        ShareLink(item: TorrentFile(url: t.url, name: t.name, client: model.http, referer: model.site.referer),
                  preview: SharePreview(t.name)) {
            Label("分享 .torrent 文件", systemImage: "square.and.arrow.up")
        }
        Button { DetailClipboard.copy(t.url, model, message: "已复制种子链接") } label: {
            Label("复制种子链接", systemImage: "doc.on.doc")
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false; loaded = true }
        do {
            let url = (detail.torrentUrl?.isEmpty == false ? detail.torrentUrl : nil)
                ?? EhURL.torrentList(model.site, gid: detail.gid, token: detail.token)
            torrents = try await model.api.getTorrentList(url: url, gid: detail.gid, token: detail.token)
            error = nil
        } catch {
            if !GalleryDetailModel.isCancellation(error) { self.error = error }
        }
    }

    /// 种子地址形如 .../get/{gid}/{40 位 info hash}.torrent
    static func magnet(for t: TorrentInfo) -> String? {
        guard let url = URL(string: t.url) else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        guard name.count == 40, name.allSatisfy(\.isHexDigit) else { return nil }
        let dn = t.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))) ?? ""
        return "magnet:?xt=urn:btih:\(name)" + (dn.isEmpty ? "" : "&dn=\(dn)")
    }

    nonisolated static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = name.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        return String((cleaned.isEmpty ? "torrent" : cleaned).prefix(150))
    }
}

/// 分享时才下载的 .torrent 文件（对应 DownloadTorrentManager.download）
struct TorrentFile: Transferable {
    let url: String
    let name: String
    let client: EhHTTPClient
    let referer: String

    static let contentType = UTType(filenameExtension: "torrent") ?? .data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: contentType) { item in
            let data = try await item.client.fetchData(item.url, referer: item.referer, timeout: 60)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("torrents", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent(TorrentListView.sanitize(item.name) + ".torrent")
            try data.write(to: file, options: .atomic)
            return SentTransferredFile(file)
        }
    }
}
