import SwiftUI
import EhCore

/// 排行榜（toplist.php）：7 个类别 × 4 个时间范围，每项最多 10 条。
/// 对应 Android `EhTopListScene` / `EhTopListAdapter`
struct TopListView: View {
    @Environment(AppModel.self) private var model

    @State private var detail: EhTopListDetail?
    @State private var error: Error?
    @State private var loading = false
    @State private var type: EhTopListDetail.ListType = .gallery
    /// 0 昨日 / 1 过去一月 / 2 过去一年 / 3 总榜（与 `TopListInfo.get` 一致）
    @State private var range = 0
    @ScaledMetric(relativeTo: .headline) private var rankWidth: CGFloat = 28

    var body: some View {
        Group {
            if let detail {
                list(detail)
            } else if let error {
                ErrorStateView(error: error) { Task { await load() } }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("排行榜")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // 菜单样式的 Picker 直接显示当前类别
                Picker("类别", selection: $type) {
                    ForEach(EhTopListDetail.ListType.allCases, id: \.self) { t in
                        Text(Self.typeTitle(t)).tag(t)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel(Text("排行榜类别"))
                .accessibilityValue(Text(Self.typeTitle(type)))
            }
        }
        .task {
            if detail == nil { await load() }
        }
    }

    private func list(_ detail: EhTopListDetail) -> some View {
        let info = detail.get(type.rawValue) ?? TopListInfo(type: type)
        let items = info.get(range)?.itemArray ?? []
        return List {
            Section {
                Picker("时间范围", selection: $range) {
                    ForEach(0..<4, id: \.self) { i in
                        Text(Self.rangeTitle(i)).tag(i)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                if items.isEmpty {
                    ContentUnavailableView("暂无数据", systemImage: "trophy",
                                           description: Text("这个榜单在“\(Self.rangeTitle(range))”范围内还没有数据。"))
                        .listRowBackground(Color.clear)
                }
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    NavigationLink(value: route(for: item)) {
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(index < 3 ? Color.orange : Color.secondary)
                                .frame(minWidth: rankWidth)
                            Text(item.value ?? "")
                                .font(.subheadline)
                                .lineLimit(3)
                        }
                    }
                }
            } header: {
                Text(info.title ?? Self.typeTitle(type))
            } footer: {
                if type == .gallery {
                    NavigationLink(value: Route.list(Self.fullListBuilder(range), title: "排行榜 · \(Self.rangeTitle(range))")) {
                        Label("查看完整榜单", systemImage: "list.number")
                            .font(.footnote)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let d = try await Task { try await model.api.getTopList(url: EhURL.topList) }.value
            detail = d
            error = nil
        } catch {
            if detail == nil { self.error = error } else { model.toast.error(error) }
        }
    }

    /// 点击条目：画廊链接→详情；站内列表链接→列表；其他按名称搜索（画廊榜为关键词，其他榜为上传者）
    private func route(for item: TopListItem) -> Route {
        if let gidStr = item.gid, let gid = Int64(gidStr), let token = item.token, !token.isEmpty {
            return .galleryToken(gid: gid, token: token)
        }
        switch EhUrlRoute.parseEhUrl(item.href) {
        case let .galleryDetail(gid, token)?:
            return .galleryToken(gid: gid, token: token)
        case let .galleryList(b)?:
            return .list(b, title: item.value)
        default:
            let value = item.value ?? ""
            if type == .gallery {
                return .list(ListUrlBuilder(mode: .normal, keyword: value), title: value)
            }
            return .list(.uploader(value), title: value)
        }
    }

    /// 完整榜单（toplist.php?tl=N 的画廊列表）。对应 `EhTopListAdapter.urlFollow`
    static func fullListBuilder(_ range: Int) -> ListUrlBuilder {
        var b = ListUrlBuilder()
        b.mode = .topList
        switch range {
        case 0: b.follow = "tl=15"
        case 1: b.follow = "tl=13"
        case 2: b.follow = "tl=12"
        default: b.follow = "tl=11"
        }
        return b
    }

    static func rangeTitle(_ i: Int) -> String {
        switch i {
        case 0: return "昨日"
        case 1: return "过去一月"
        case 2: return "过去一年"
        default: return "总榜"
        }
    }

    static func typeTitle(_ t: EhTopListDetail.ListType) -> String {
        switch t {
        case .gallery: return "画廊"
        case .uploader: return "上传者"
        case .tagging: return "标签贡献"
        case .hentaiHome: return "Hentai@Home"
        case .ehTracker: return "EHTracker"
        case .cleanup: return "清理"
        case .ratingAndReviewing: return "评分与评论"
        }
    }
}
