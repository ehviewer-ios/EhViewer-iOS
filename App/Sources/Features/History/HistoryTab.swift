import SwiftUI
import EhCore
import EhStorage

/// 历史标签页。对应 Android `HistoryScene`：
/// 列表（`observeHistory`，按时间降序，今天 / 昨天 / 更早 分组并显示浏览时间）、点击进入详情、
/// 左滑删除、清空（确认）、长按菜单（复用 `GalleryContextMenu`）、搜索。
struct HistoryTab: View {
    @Environment(AppModel.self) private var model
    @State private var path = NavigationPath()
    @State private var history: [HistoryInfo] = []
    @State private var loaded = false
    @State private var loadError: Error?
    @State private var searchText = ""
    @State private var searchPresented = false
    @State private var confirmClear = false
    @State private var clearedTick = 0
    /// 用于跨天时刷新分组
    @State private var today = Calendar.current.startOfDay(for: Date())

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("历史")
                .navigationBarTitleDisplayMode(.inline)
                .listSearchable(text: $searchText, isPresented: $searchPresented, prompt: "搜索历史")
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button(role: .destructive) {
                            confirmClear = true
                        } label: {
                            Label("清空历史", systemImage: "trash")
                        }
                        .disabled(history.isEmpty)
                        ListSearchButton { searchPresented = true }
                    }
                }
                .sensoryFeedback(.success, trigger: clearedTick)
                .confirmationDialog("清空 \(history.count) 条浏览历史？", isPresented: $confirmClear,
                                    titleVisibility: .visible) {
                    Button("清空历史", role: .destructive) { clear() }
                } message: {
                    Text("此操作无法撤销。")
                }
                .withAppRoutes()
        }
        .navigate(appendingTo: $path)
        .task { await observe() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            today = Calendar.current.startOfDay(for: Date())
        }
    }

    // MARK: 数据

    private func observe() async {
        do {
            for try await list in model.database.observeHistory() {
                history = list
                loaded = true
                loadError = nil
            }
        } catch {
            guard !(error is CancellationError) else { return }
            loadError = error
            loaded = true
        }
    }

    private var filtered: [HistoryInfo] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return history }
        return history.filter { h in
            [h.title, h.titleJpn, h.uploader].contains { $0?.localizedCaseInsensitiveContains(q) ?? false }
        }
    }

    private enum Bucket: Int, CaseIterable {
        case today, yesterday, earlier
        var title: String {
            switch self {
            case .today: return "今天"
            case .yesterday: return "昨天"
            case .earlier: return "更早"
            }
        }
    }

    private func bucket(_ h: HistoryInfo) -> Bucket {
        let d = Date(timeIntervalSince1970: TimeInterval(h.time) / 1000)
        if d >= today { return .today }
        if let y = Calendar.current.date(byAdding: .day, value: -1, to: today), d >= y { return .yesterday }
        return .earlier
    }

    private var groups: [(Bucket, [HistoryInfo])] {
        let dict = Dictionary(grouping: filtered, by: bucket)
        return Bucket.allCases.compactMap { b in dict[b].map { (b, $0) } }
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if !loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError, history.isEmpty {
            ErrorStateView(error: loadError) {
                self.loadError = nil
                loaded = false
                Task { await observe() }
            }
        } else if history.isEmpty {
            EmptyStateView(title: "没有浏览历史", systemImage: "clock", message: "打开过的画廊会显示在这里。")
        } else if filtered.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List {
                ForEach(groups, id: \.0) { bucket, items in
                    Section(bucket.title) {
                        ForEach(items) { h in
                            row(h, bucket: bucket)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func row(_ h: HistoryInfo, bucket: Bucket) -> some View {
        let info = h.galleryInfo
        return NavigationLink(value: Route.gallery(info)) {
            GalleryRow(info: info, thumbWidth: model.setting(\.detailSize) == .short ? 64 : 84) {
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.caption2)
                    Text(timeText(h, bucket: bucket)).font(.caption2.monospacedDigit())
                    Spacer()
                    if let state = model.downloadState(gid: info.gid) {
                        GalleryDownloadBadge(state: state)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            GalleryContextMenu(info: info)
            Section {
                Button(role: .destructive) {
                    delete(h)
                } label: {
                    Label("删除记录", systemImage: "trash")
                }
            }
        } preview: {
            GalleryContextPreview(info: info).environment(model)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                delete(h)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func timeText(_ h: HistoryInfo, bucket: Bucket) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(h.time) / 1000)
        switch bucket {
        case .today, .yesterday:
            return d.formatted(date: .omitted, time: .shortened)
        case .earlier:
            return d.formatted(date: .abbreviated, time: .shortened)
        }
    }

    // MARK: 操作

    private func delete(_ h: HistoryInfo) {
        do {
            try model.database.deleteHistoryInfo(h)
        } catch {
            model.toast.error(error)
        }
    }

    private func clear() {
        do {
            try model.database.clearHistoryInfo()
            clearedTick += 1
        } catch {
            model.toast.error(error)
        }
    }
}
