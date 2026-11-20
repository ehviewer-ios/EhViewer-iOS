import Foundation

/// 画廊过滤器（标题 / 上传者 / tag / tag 命名空间）与评论黑名单。对应 Android `client/EhFilter.java`
/// （黑名单部分对应 `EhDB.inBlackList` 在 `GalleryDetailParser` 中的用法）。
///
/// 所有 `filterXxx` 返回 true 表示**保留**，false 表示应被过滤掉（与 Android 一致）。
/// 线程安全：内部用锁保护规则列表。
public final class EhFilter: @unchecked Sendable {
    public enum Mode: Int, CaseIterable, Sendable {
        case title = 0
        case uploader = 1
        case tag = 2
        case tagNamespace = 3
    }

    private let database: EhDatabase
    private let lock = NSLock()
    // 规则文本：title / tag / tagNamespace 已转小写（与 Android 构造时一致），uploader 保持原样
    private var titleFilters: [Filter] = []
    private var uploaderFilters: [Filter] = []
    private var tagFilters: [Filter] = []
    private var tagNamespaceFilters: [Filter] = []
    private var blackListNames: Set<String> = []

    /// 从数据库加载全部规则
    public init(database: EhDatabase) throws {
        self.database = database
        try reload()
    }

    /// 重新从数据库加载（导入数据库后调用）
    public func reload() throws {
        let filters = try database.allFilters()
        let black = try database.allBlackList()
        lock.withLock {
            titleFilters = []
            uploaderFilters = []
            tagFilters = []
            tagNamespaceFilters = []
            for f in filters { appendLocked(f) }
            blackListNames = Set(black.compactMap(\.badgayname))
        }
    }

    private func appendLocked(_ filter: Filter) {
        var f = filter
        switch Mode(rawValue: f.mode) {
        case .title:
            f.text = f.text?.lowercased()
            titleFilters.append(f)
        case .uploader:
            uploaderFilters.append(f)
        case .tag:
            f.text = f.text?.lowercased()
            tagFilters.append(f)
        case .tagNamespace:
            f.text = f.text?.lowercased()
            tagNamespaceFilters.append(f)
        case nil:
            break // Unknown mode
        }
    }

    public var titleFilterList: [Filter] { lock.withLock { titleFilters } }
    public var uploaderFilterList: [Filter] { lock.withLock { uploaderFilters } }
    public var tagFilterList: [Filter] { lock.withLock { tagFilters } }
    public var tagNamespaceFilterList: [Filter] { lock.withLock { tagNamespaceFilters } }

    // MARK: - 规则增删

    /// 对应 `addFilter`：写库前强制启用
    @discardableResult
    public func addFilter(_ filter: Filter) throws -> Filter {
        var f = filter
        f.enable = true
        let saved = try database.addFilter(f)
        lock.withLock { appendLocked(saved) }
        return saved
    }

    /// 对应 `triggerFilter`：切换启用状态
    @discardableResult
    public func triggerFilter(_ filter: Filter) throws -> Filter {
        let updated = try database.triggerFilter(filter)
        lock.withLock {
            func toggle(_ list: inout [Filter]) {
                for i in list.indices where list[i].id == updated.id { list[i].enable = updated.enable }
            }
            toggle(&titleFilters); toggle(&uploaderFilters); toggle(&tagFilters); toggle(&tagNamespaceFilters)
        }
        return updated
    }

    /// 对应 `deleteFilter`
    public func deleteFilter(_ filter: Filter) throws {
        try database.deleteFilter(filter)
        lock.withLock {
            func remove(_ list: inout [Filter]) {
                if let id = filter.id {
                    list.removeAll { $0.id == id }
                } else if let i = list.firstIndex(where: {
                    $0.mode == filter.mode && ($0.text == filter.text || $0.text == filter.text?.lowercased())
                }) {
                    list.remove(at: i)
                }
            }
            switch Mode(rawValue: filter.mode) {
            case .title: remove(&titleFilters)
            case .uploader: remove(&uploaderFilters)
            case .tag: remove(&tagFilters)
            case .tagNamespace: remove(&tagNamespaceFilters)
            case nil: break
            }
        }
    }

    /// 对应 `needTags`：有 tag / 命名空间规则时，列表需要通过 API 补全 tag
    public var needTags: Bool {
        lock.withLock { !tagFilters.isEmpty || !tagNamespaceFilters.isEmpty }
    }

    // MARK: - 过滤判断（true = 保留）

    /// 对应 `filterTitle`：标题（小写）包含任一启用的规则文本则过滤
    public func filterTitle(_ info: GalleryInfo) -> Bool {
        guard let title = info.title else { return true }
        let filters = lock.withLock { titleFilters }
        if filters.isEmpty { return true }
        let lower = title.lowercased()
        for f in filters where f.isEnabled {
            if let text = f.text, text.isEmpty || lower.contains(text) { return false }
        }
        return true
    }

    /// 对应 `filterUploader`：上传者与规则完全相等（区分大小写）则过滤
    public func filterUploader(_ info: GalleryInfo) -> Bool {
        guard let uploader = info.uploader else { return true }
        let filters = lock.withLock { uploaderFilters }
        for f in filters where f.isEnabled && uploader == f.text {
            return false
        }
        return true
    }

    /// 对应 `filterTag`
    public func filterTag(_ info: GalleryInfo) -> Bool {
        guard let tags = info.simpleTags else { return true }
        let filters = lock.withLock { tagFilters }
        if filters.isEmpty { return true }
        for tag in tags {
            for f in filters where f.isEnabled && Self.matchTag(tag, f.text) {
                return false
            }
        }
        return true
    }

    /// 对应 `filterTagNamespace`
    public func filterTagNamespace(_ info: GalleryInfo) -> Bool {
        guard let tags = info.simpleTags else { return true }
        let filters = lock.withLock { tagNamespaceFilters }
        if filters.isEmpty { return true }
        for tag in tags {
            for f in filters where f.isEnabled && Self.matchTagNamespace(tag, f.text) {
                return false
            }
        }
        return true
    }

    /// 全部规则（标题、上传者、tag、命名空间）都通过时返回 true
    public func filter(_ info: GalleryInfo) -> Bool {
        filterTitle(info) && filterUploader(info) && filterTag(info) && filterTagNamespace(info)
    }

    /// 对应 `EhEngine.fillGalleryList` 第一轮（API 补全 tag 前）：标题 + 上传者
    public func filterBeforeTags(_ info: GalleryInfo) -> Bool {
        filterTitle(info) && filterUploader(info)
    }

    /// 对应 `EhEngine.fillGalleryList` 第二轮（补全 tag 后）：上传者 + tag + 命名空间
    public func filterAfterTags(_ info: GalleryInfo) -> Bool {
        filterUploader(info) && filterTag(info) && filterTagNamespace(info)
    }

    /// 过滤列表，保留通过的项
    public func filter(_ list: [GalleryInfo]) -> [GalleryInfo] {
        list.filter { filter($0) }
    }

    /// 对应 `matchTag`：命名空间都存在时需相等；名称需相等
    static func matchTag(_ tag: String?, _ filter: String?) -> Bool {
        guard let tag, let filter else { return false }
        let (tagNamespace, tagName) = split(tag)
        let (filterNamespace, filterName) = split(filter)
        if let tagNamespace, let filterNamespace, tagNamespace != filterNamespace {
            return false
        }
        return tagName == filterName
    }

    /// 对应 `matchTagNamespace`
    static func matchTagNamespace(_ tag: String?, _ filter: String?) -> Bool {
        guard let tag, let filter, let colon = tag.firstIndex(of: ":") else { return false }
        return String(tag[..<colon]) == filter
    }

    private static func split(_ s: String) -> (String?, String) {
        guard let colon = s.firstIndex(of: ":") else { return (nil, s) }
        return (String(s[..<colon]), String(s[s.index(after: colon)...]))
    }

    // MARK: - 黑名单

    /// 评论者是否在黑名单（对应 `EhDB.inBlackList`，使用内存缓存）
    public func isBlacklisted(_ user: String?) -> Bool {
        guard let user else { return false }
        return lock.withLock { blackListNames.contains(user) }
    }

    /// 加入黑名单（写库并更新缓存）。对应 `EhDB.insertBlackList(BlackListUtils.parseBlacklist(comment))`
    @discardableResult
    public func addToBlackList(_ blackList: BlackList) throws -> BlackList? {
        let saved = try database.insertBlackList(blackList)
        if let name = saved?.badgayname { _ = lock.withLock { blackListNames.insert(name) } }
        return saved
    }

    public func removeFromBlackList(_ blackList: BlackList) throws {
        try database.deleteBlackList(blackList)
        let remaining = try database.allBlackList()
        lock.withLock { blackListNames = Set(remaining.compactMap(\.badgayname)) }
    }

    /// 过滤评论列表：去掉黑名单用户的评论（对应 `GalleryDetailParser` 中的 `!EhDB.inBlackList(comment.user)`）
    public func filterComments<T>(_ comments: [T], user: (T) -> String?) -> [T] {
        let names = lock.withLock { blackListNames }
        if names.isEmpty { return comments }
        return comments.filter { c in user(c).map { !names.contains($0) } ?? true }
    }
}
