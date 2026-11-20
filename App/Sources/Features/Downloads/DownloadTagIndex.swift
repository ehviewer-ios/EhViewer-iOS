import SwiftUI
import EhCore
import EhStorage
import EhNetwork

/// 下载画廊的标签，用于下载列表的标签搜索与建议。
/// 标签存于 `Gallery_Tags`（与 Android 相同）：打开详情页时写入完整标签（对应 `GalleryDetailTagsSyncTask`），
/// 下载列表中缺少的通过 gdata 分批补齐（每批 25 个）。
@MainActor @Observable
final class DownloadTagIndex {
    /// gid -> 带命名空间的标签（只含下载列表中的画廊）
    private(set) var tagsByGid: [Int64: [String]] = [:]
    /// 建议的候选：下载中出现过的标签与出现次数。标签变化后重建
    @ObservationIgnored private var candidates: [Candidate]?
    /// 本次运行中已尝试补齐的画廊（失败的不重复请求）
    @ObservationIgnored private var attempted: Set<Int64> = []
    @ObservationIgnored private var backfillTask: Task<Void, Never>?
    @ObservationIgnored private let database: EhDatabase

    struct Candidate: Sendable {
        let namespace: String
        let name: String
        let count: Int
    }

    init(database: EhDatabase) {
        self.database = database
    }

    func tags(for gid: Int64) -> [String] { tagsByGid[gid] ?? [] }

    /// 读取下载画廊的标签，缺少的在后台通过 gdata 补齐。下载列表出现、下载项增减时调用
    func refresh(_ model: AppModel) {
        let infos = model.downloads.allInfoList.filter { !DownloadDisplay.isLocal($0) && !($0.token ?? "").isEmpty }
        let unknown = infos.map(\.gid).filter { tagsByGid[$0] == nil }
        if !unknown.isEmpty, let rows = try? database.galleryTags(gids: unknown), !rows.isEmpty {
            for row in rows { tagsByGid[row.gid] = row.namespacedTags }
            candidates = nil
        }
        let missing = infos.filter { tagsByGid[$0.gid] == nil && !attempted.contains($0.gid) }
        backfill(missing, model: model)
    }

    /// 详情页加载后调用：保存完整标签。`isDownloaded` 时同时更新索引
    func record(gid: Int64, groups: [GalleryTagGroup], isDownloaded: Bool) {
        guard !groups.isEmpty else { return }
        let row = GalleryTags(gid: gid, groups: groups)
        let db = database
        Task.detached(priority: .utility) { try? db.saveGalleryTags(row) }
        if isDownloaded { apply([row]) }
    }

    private func apply(_ rows: [GalleryTags]) {
        guard !rows.isEmpty else { return }
        for row in rows { tagsByGid[row.gid] = row.namespacedTags }
        candidates = nil
    }

    private func backfill(_ infos: [DownloadInfo], model: AppModel) {
        guard backfillTask == nil, !infos.isEmpty else { return }
        let targets = infos.map { GalleryInfo(gid: $0.gid, token: $0.token ?? "") }
        attempted.formUnion(targets.map(\.gid))
        let api = model.api
        let referer = model.site.referer
        let db = database
        backfillTask = Task { [weak self] in
            var start = 0
            while start < targets.count, !Task.isCancelled {
                let end = min(start + EhAPI.maxGdataRequestSize, targets.count)
                let filled = await api.fillGalleryListByApiBestEffort(Array(targets[start..<end]), referer: referer)
                let rows = filled.compactMap { gi -> GalleryTags? in
                    guard let tags = gi.simpleTags, !tags.isEmpty else { return nil }
                    return GalleryTags(gid: gi.gid, namespacedTags: tags)
                }
                await Task.detached(priority: .utility) { for row in rows { try? db.saveGalleryTags(row) } }.value
                self?.apply(rows)
                start = end
                if start < targets.count { try? await Task.sleep(for: .milliseconds(500)) }
            }
            self?.backfillTask = nil
        }
    }

    // MARK: 建议

    private func currentCandidates() -> [Candidate] {
        if let candidates { return candidates }
        var counts: [String: Int] = [:]
        for tags in tagsByGid.values {
            for tag in Set(tags) { counts[tag, default: 0] += 1 }
        }
        let list = counts.map { tag, count -> Candidate in
            let colon = tag.firstIndex(of: ":") ?? tag.startIndex
            let namespace = colon == tag.startIndex ? "misc" : String(tag[..<colon])
            let name = colon == tag.startIndex ? tag : String(tag[tag.index(after: colon)...])
            return Candidate(namespace: namespace, name: name, count: count)
        }
        candidates = list
        return list
    }

    /// 下载中出现过、英文名或中文翻译包含关键字的标签：前缀匹配优先，其次按出现次数
    func suggestions(for keyword: String, translation: TagTranslation?) async -> [DownloadTagSuggestion] {
        let k = keyword.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return [] }
        let list = currentCandidates()
        return await Task.detached(priority: .userInitiated) {
            Self.match(k, in: list, translation: translation)
        }.value
    }

    nonisolated static func match(_ keyword: String, in candidates: [Candidate], translation: TagTranslation?,
                                  limit: Int = 30) -> [DownloadTagSuggestion] {
        let k = keyword.lowercased()
        var ranked: [(DownloadTagSuggestion, Bool)] = []
        for c in candidates {
            let prefix = TagTranslation.namespaceToPrefixMap[c.namespace] ?? ""
            let zh = translation?.getTranslation(prefix + c.name)
            let nameHit = c.name.contains(k)
            let zhHit = zh?.contains(keyword) ?? false
            guard nameHit || zhHit else { continue }
            let starts = c.name.hasPrefix(k) || (zh?.hasPrefix(keyword) ?? false)
            let s = DownloadTagSuggestion(tag: "\(c.namespace):\(c.name)", translation: zh,
                                          namespaceTranslation: translation?.getTranslation("n:" + c.namespace),
                                          count: c.count)
            ranked.append((s, starts))
        }
        ranked.sort { a, b in
            if a.1 != b.1 { return a.1 }
            if a.0.count != b.0.count { return a.0.count > b.0.count }
            return a.0.tag < b.0.tag
        }
        return ranked.prefix(limit).map(\.0)
    }
}

struct DownloadTagSuggestion: Identifiable, Sendable, Hashable {
    /// 带命名空间的标签，如 `female:big breasts`
    let tag: String
    let translation: String?
    let namespaceTranslation: String?
    /// 下载中带有此标签的画廊数
    let count: Int

    var id: String { tag }
}

/// 下载列表的标签建议面板（编辑搜索框时盖在列表上）：点按只补全搜索框，不提交（同浏览页）
struct DownloadTagSuggestionList: View {
    let suggestions: [DownloadTagSuggestion]
    var onFill: (DownloadTagSuggestion) -> Void

    var body: some View {
        List(suggestions) { s in
            Button {
                onFill(s)
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let zh = s.translation {
                            Text(zh).foregroundStyle(.primary)
                            Text(s.tag).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(s.tag).foregroundStyle(.primary)
                        }
                    }
                    Spacer(minLength: 8)
                    Text("\(s.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("\(s.count) 个画廊"))
                }
                .contentShape(Rectangle())
            }
            .accessibilityHint("填入搜索框")
            .accessibilityIdentifier("download-tag-suggestion")
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        .background(Color(.systemBackground))
    }
}
