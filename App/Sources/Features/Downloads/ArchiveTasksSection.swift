import SwiftUI
import EhCore
import EhStorage
import EhSpider

/// 归档 zip 下载任务的进度（订阅 `ArchiverDownloader.events`）。对应 Android `ArchiverDownloadService` 的通知进度
@MainActor @Observable
final class ArchiveTasksModel {
    struct Item: Identifiable, Equatable {
        var gid: Int64
        var progress: ArchiverProgress?
        var error: String?
        var importing = false
        var id: Int64 { gid }
    }

    private(set) var items: [Item] = []
    @ObservationIgnored private var titles: [Int64: String] = [:]
    @ObservationIgnored private weak var app: AppModel?

    /// 在视图的 `.task` 中调用：先读取当前任务快照，再持续订阅事件（任务取消时返回）
    func run(_ model: AppModel) async {
        app = model
        let archiver = model.archiver
        let events = archiver.events
        let gids = await archiver.activeGids
        var snapshot: [Item] = []
        for gid in gids.sorted() {
            snapshot.append(Item(gid: gid, progress: await archiver.progress(gid: gid)))
        }
        // 保留失败项（便于用户看到原因）
        items = snapshot + items.filter { $0.error != nil && !gids.contains($0.gid) }
        for await event in events {
            handle(event)
        }
    }

    func title(_ gid: Int64) -> String {
        if let t = titles[gid] { return t }
        guard let app else { return "画廊 \(gid)" }
        let t: String
        if let info = app.downloads.downloadInfo(gid) {
            t = app.title(of: info.galleryInfo)
        } else if let h = (try? app.database.allHistory())?.first(where: { $0.gid == gid }) {
            t = app.title(of: h.galleryInfo)
        } else {
            t = "画廊 \(gid)"
        }
        titles[gid] = t
        return t
    }

    func pause(_ gid: Int64) {
        guard let app else { return }
        Task { await app.archiver.pause(gid: gid) }
    }

    func resume(_ gid: Int64) {
        guard let app else { return }
        Task { await app.archiver.resume(gid: gid) }
    }

    func cancel(_ gid: Int64) {
        guard let app else { return }
        Task { await app.archiver.cancel(gid: gid) }
        remove(gid)
    }

    func dismiss(_ gid: Int64) { remove(gid) }

    private func remove(_ gid: Int64) {
        items.removeAll { $0.gid == gid }
    }

    private func upsert(_ gid: Int64, _ body: (inout Item) -> Void) {
        if let i = items.firstIndex(where: { $0.gid == gid }) {
            body(&items[i])
        } else {
            var item = Item(gid: gid)
            body(&item)
            items.append(item)
        }
    }

    private func handle(_ event: ArchiverEvent) {
        switch event {
        case let .progress(p):
            upsert(p.gid) {
                $0.progress = p
                $0.error = nil
            }
        case let .success(gid, _, _):
            upsert(gid) { $0.importing = true }
        case let .failure(gid, _, error):
            upsert(gid) {
                $0.error = error
                $0.importing = false
            }
        case let .cancelled(gid, _):
            remove(gid)
        case let .imported(gid, _):
            remove(gid)
            app?.toast.show("归档已导入：\(title(gid))", systemImage: "archivebox")
        }
    }
}

/// 下载列表顶部的归档任务区域
struct ArchiveTasksSection: View {
    let tasks: ArchiveTasksModel

    var body: some View {
        if !tasks.items.isEmpty {
            Section {
                ForEach(tasks.items) { item in
                    ArchiveTaskRow(item: item, title: tasks.title(item.gid), tasks: tasks)
                }
            } header: {
                Label("归档下载", systemImage: "archivebox")
            }
        }
    }
}

struct ArchiveTaskRow: View {
    let item: ArchiveTasksModel.Item
    let title: String
    let tasks: ArchiveTasksModel
    @State private var confirmCancel = false
    @ScaledMetric(relativeTo: .title2) private var iconWidth: CGFloat = 32

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.zipper")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline).lineLimit(2)
                if let error = item.error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else if item.importing {
                    ProgressView().progressViewStyle(.linear)
                    Text("正在解压导入…").font(.caption).foregroundStyle(.secondary)
                } else if let p = item.progress {
                    if p.total > 0 {
                        ProgressView(value: Double(min(p.downloaded, p.total)), total: Double(p.total))
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(detailText(p)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("等待中").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            controls
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 4) {
            if item.error != nil {
                controlButton("xmark.circle", title: "移除") {
                    tasks.dismiss(item.gid)
                }
            } else if !item.importing {
                if let p = item.progress {
                    controlButton(p.paused ? "play.circle" : "pause.circle", title: p.paused ? "继续" : "暂停") {
                        if p.paused { tasks.resume(item.gid) } else { tasks.pause(item.gid) }
                    }
                    .sensoryFeedback(.impact(weight: .light), trigger: p.paused)
                }
                controlButton("stop.circle", title: "取消下载", tint: .red) {
                    confirmCancel = true
                }
            }
        }
        .confirmationDialog("取消归档下载？", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("取消下载", role: .destructive) { tasks.cancel(item.gid) }
            Button("继续下载", role: .cancel) {}
        } message: {
            Text("已花费的 GP 不会退还，再次下载需要重新支付。")
        }
    }

    private func controlButton(_ systemImage: String, title: String, tint: Color? = nil,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint ?? Color.accentColor)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(title))
    }

    private func detailText(_ p: ArchiverProgress) -> String {
        var parts: [String] = []
        if p.total > 0 {
            parts.append("\(DownloadDisplay.byteText(p.downloaded)) / \(DownloadDisplay.byteText(p.total))")
        } else {
            parts.append(DownloadDisplay.byteText(p.downloaded))
        }
        if p.paused {
            parts.append("已暂停")
        } else {
            parts.append(DownloadDisplay.speedText(p.speed))
            if let r = DownloadDisplay.remainingText(p.remaining) { parts.append(r) }
        }
        return parts.joined(separator: " · ")
    }
}
