import Foundation

/// 本地画廊搜索（下载列表）。支持站点搜索语法的常用部分，在线搜索的写法（包括标签建议补全出的 `l:"chinese$"`）可以直接用：
/// - 空格分隔的词需全部满足；`"..."` 内的空格不分词
/// - `命名空间:值`：命名空间可以是全称（female）或简写（f）；值以 `$` 结尾为精确匹配，否则包含即可
/// - `uploader:名字`：上传者
/// - `-词`：排除；`~词`：这些词中至少满足一个
/// - 其他词：匹配标题（英文 / 日文）、上传者、下载标签，或任一标签名；`词$` 只精确匹配标签名
/// - 命名空间无法识别时（如标题里的 `Re:Zero`）整个词按普通词处理
///
/// 对应 Android `DownloadListInfosExecutor`（标题或标签匹配），语法扩展为与站点一致。
public struct LocalGallerySearch: Sendable, Equatable {
    /// 被搜索的画廊
    public struct Item: Sendable {
        public var titles: [String]
        public var uploader: String?
        public var label: String?
        /// 带命名空间的标签，如 `female:big breasts`；没有命名空间的视为 misc
        public var tags: [String]

        public init(titles: [String], uploader: String? = nil, label: String? = nil, tags: [String] = []) {
            self.titles = titles
            self.uploader = uploader
            self.label = label
            self.tags = tags
        }
    }

    enum Term: Sendable, Equatable {
        case text(String, exact: Bool)
        case tag(namespace: String, name: String, exact: Bool)
        case uploader(String)
    }

    struct Clause: Sendable, Equatable {
        var term: Term
        var negated = false
        var optional = false
    }

    let clauses: [Clause]

    public init(_ query: String) {
        clauses = Self.tokenize(query).compactMap(Self.clause)
    }

    public var isEmpty: Bool { clauses.isEmpty }

    public func matches(_ item: Item) -> Bool {
        guard !clauses.isEmpty else { return true }
        let p = Prepared(item)
        var hasOptional = false
        var optionalMatched = false
        for c in clauses {
            let m = p.matches(c.term)
            if c.negated {
                if m { return false }
            } else if c.optional {
                hasOptional = true
                if m { optionalMatched = true }
            } else if !m {
                return false
            }
        }
        return !hasOptional || optionalMatched
    }

    // MARK: 解析

    /// 按空白分词，引号内不分词（引号保留在词中，未闭合的引号到末尾为止）
    static func tokenize(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in query {
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
            } else if ch.isWhitespace, !inQuotes {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func clause(_ token: String) -> Clause? {
        var t = Substring(token)
        var c = Clause(term: .text("", exact: false))
        if t.count > 1, t.first == "-" {
            c.negated = true
            t = t.dropFirst()
        } else if t.count > 1, t.first == "~" {
            c.optional = true
            t = t.dropFirst()
        }
        // 引号外的第一个冒号前为命名空间
        if let colon = t.firstIndex(of: ":"), colon != t.startIndex, !t[..<colon].contains("\"") {
            let ns = t[..<colon].lowercased()
            let (value, exact) = normalize(t[t.index(after: colon)...])
            if ns == "uploader" {
                guard !value.isEmpty else { return nil }
                c.term = .uploader(value)
                return c
            }
            if let namespace = resolveNamespace(ns) {
                guard !value.isEmpty else { return nil }
                c.term = .tag(namespace: namespace, name: value, exact: exact)
                return c
            }
        }
        let (value, exact) = normalize(t)
        guard !value.isEmpty else { return nil }
        c.term = .text(value, exact: exact)
        return c
    }

    /// 去掉引号与表示精确匹配的 `$`（引号内外均可），转小写
    static func normalize(_ s: Substring) -> (String, exact: Bool) {
        var v = String(s).trimmingCharacters(in: .whitespaces)
        var exact = false
        if v.hasSuffix("$") {
            exact = true
            v.removeLast()
        }
        v = v.replacingOccurrences(of: "\"", with: "")
        if v.hasSuffix("$") {
            exact = true
            v.removeLast()
        }
        return (v.trimmingCharacters(in: .whitespaces).lowercased(), exact)
    }

    static let namespaces: Set<String> = [
        "artist", "character", "cosplayer", "female", "group", "language", "location",
        "male", "misc", "mixed", "other", "parody", "reclass", "temp",
    ]

    /// 全称或站点简写（f、l、cos 等）-> 全称
    static func resolveNamespace(_ s: String) -> String? {
        if namespaces.contains(s) { return s }
        // n: 是翻译数据库中命名空间本身的前缀，不是搜索语法
        guard s != "n", let full = TagTranslation.prefixToNamespace(s + ":") else { return nil }
        return full
    }

    // MARK: 匹配

    private struct Prepared {
        var texts: [String]
        var uploader: String
        var tags: [(namespace: String, name: String)]

        init(_ item: Item) {
            texts = (item.titles + [item.uploader, item.label].compactMap { $0 })
                .filter { !$0.isEmpty }
                .map { $0.lowercased() }
            uploader = item.uploader?.lowercased() ?? ""
            tags = item.tags.map { raw in
                let s = raw.lowercased()
                guard let colon = s.firstIndex(of: ":") else { return ("misc", s) }
                return (String(s[..<colon]), String(s[s.index(after: colon)...]))
            }
        }

        func matches(_ term: Term) -> Bool {
            switch term {
            case let .text(word, exact):
                if exact { return tags.contains { $0.name == word } }
                return texts.contains { $0.contains(word) } || tags.contains { $0.name.contains(word) }
            case let .tag(namespace, name, exact):
                return tags.contains { $0.namespace == namespace && (exact ? $0.name == name : $0.name.contains(name)) }
            case let .uploader(name):
                return uploader.contains(name)
            }
        }
    }
}
