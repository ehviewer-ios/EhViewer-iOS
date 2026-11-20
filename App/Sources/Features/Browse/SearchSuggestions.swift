import SwiftUI
import UIKit
import EhCore

/// 搜索历史（UserDefaults 持久化，最近在前）。对应 Android `SearchDatabase`
@MainActor @Observable
final class SearchHistoryStore {
    static let shared = SearchHistoryStore()

    private static let key = "browse.searchHistory"
    private static let limit = 128

    private(set) var items: [String]

    private init() {
        items = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
    }

    func add(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        items.removeAll { $0 == q }
        items.insert(q, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        save()
    }

    func remove(_ query: String) {
        items.removeAll { $0 == query }
        save()
    }

    func clear() {
        items = []
        save()
    }

    /// 对应 `SearchDatabase.getSuggestions(prefix, limit)`：包含输入的历史
    func matching(_ text: String, limit: Int) -> [String] {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return Array(items.prefix(limit)) }
        return Array(items.lazy.filter { $0 != t && $0.localizedCaseInsensitiveContains(t) }.prefix(limit))
    }

    private func save() {
        UserDefaults.standard.set(items, forKey: Self.key)
    }
}

/// 搜索范围（search scopes）
enum BrowseSearchScope: String, CaseIterable, Hashable {
    case keyword, uploader, tag

    var title: String {
        switch self {
        case .keyword: return "关键词"
        case .uploader: return "上传者"
        case .tag: return "标签"
        }
    }
}

/// 标签翻译建议的关键字处理。对应 Android `SearchBar.updateSuggestions` / `TagSuggestion.rebuildKeyword`
enum TagSuggestionHelper {
    /// 输入末尾尚未成为 tag 的若干个词（遇到含 ":" 或 "$" 的词停止）
    static func pendingKeyword(in text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var collected: [String] = []
        for w in words.reversed() {
            if w.contains(":") || w.contains("$") { break }
            collected.insert(w, at: 0)
        }
        return collected.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// "female:big breasts" -> `f:"big breasts$"`
    static func searchKeyword(forTag english: String) -> String {
        let parts = english.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let prefix = TagTranslation.namespaceToPrefixMap[parts[0]] else { return english }
        return prefix + "\"" + parts[1] + "$\""
    }

    /// 用选中的 tag 替换输入末尾的未完成关键字，返回新的完整输入
    static func completion(of text: String, withTag english: String) -> String {
        let tagKey = searchKeyword(forTag: english)
        let pending = pendingKeyword(in: text)
        var head = text
        if !pending.isEmpty, let r = head.range(of: pending, options: .backwards) {
            head = String(head[..<r.lowerBound])
        }
        head = head.trimmingCharacters(in: .whitespaces)
        return (head.isEmpty ? "" : head + " ") + tagKey + " "
    }

    /// tag 搜索范围使用的纯 tag 文本："female:big breasts"
    static func plainTag(_ english: String) -> String { english }

    /// 标签页搜索框中可编辑的关键词，保留完整命名空间、精确匹配。对应 Android `wrapTagKeyword`（另补 `$`）：
    /// "female:big breasts" -> `female:"big breasts$"`；"language:chinese" -> `language:chinese$`
    static func editableKeyword(forTag tag: String) -> String {
        let t = tag.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return "" }
        let parts = t.split(separator: ":", maxSplits: 1).map(String.init)
        let (namespace, body) = parts.count == 2 ? (parts[0] + ":", parts[1]) : ("", t)
        // 已带引号或 $ 的保持原样
        if body.hasPrefix("\"") || body.hasSuffix("$") { return t }
        return namespace + (body.contains(" ") ? "\"\(body)$\"" : "\(body)$")
    }
}

/// 搜索建议面板，编辑搜索框时盖在列表上：链接直达、搜索历史（点按直接搜索）、标签翻译建议（点按填入，可继续追加）。
/// 不用系统的 `.searchSuggestions`：其中任何一行被点按都会直接提交搜索，标签建议就做不到只填入
struct BrowseSearchSuggestions: View {
    @Environment(AppModel.self) private var model
    let text: String
    let scope: BrowseSearchScope
    let tagSuggestions: [TagSuggestion]
    var onOpenRoute: (Route) -> Void
    /// 点按搜索历史：用这条记录搜索
    var onSearch: (String) -> Void
    /// 点按标签建议：补全搜索框，不提交
    var onFillText: (String) -> Void
    /// 请求清除全部搜索历史（由宿主视图确认）
    var onRequestClearHistory: () -> Void

    private var history: SearchHistoryStore { .shared }

    /// 是否有建议可显示（没有时编辑中也显示列表本身）
    static func hasContent(text: String, tagSuggestions: [TagSuggestion]) -> Bool {
        linkRoute(for: text) != nil || !tagSuggestions.isEmpty
            || !SearchHistoryStore.shared.matching(text, limit: 1).isEmpty
    }

    var body: some View {
        List {
            if let route = Self.linkRoute(for: text) {
                Button {
                    onOpenRoute(route)
                } label: {
                    Label("打开链接", systemImage: "link")
                }
            }

            let hist = history.matching(text, limit: text.isEmpty ? 20 : 5)
            ForEach(hist, id: \.self) { q in
                Button {
                    onSearch(q)
                } label: {
                    Label {
                        Text(q).foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { history.remove(q) } label: { Label("删除", systemImage: "trash") }
                }
                .contextMenu {
                    Button(role: .destructive) { history.remove(q) } label: { Label("删除此记录", systemImage: "trash") }
                }
            }
            if text.isEmpty, !history.items.isEmpty {
                Button(role: .destructive) {
                    onRequestClearHistory()
                } label: {
                    Label("清除搜索历史", systemImage: "trash")
                }
            }

            // 对应 Android TagSuggestion.onClick：只替换输入末尾的关键字（光标在末尾），便于连续组合多个标签
            ForEach(tagSuggestions, id: \.english) { s in
                let completion = scope == .keyword
                    ? TagSuggestionHelper.completion(of: text, withTag: s.english)
                    : TagSuggestionHelper.plainTag(s.english)
                Button {
                    onFillText(completion)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        if model.setting(\.showTagTranslations), !s.chinese.isEmpty {
                            Text(s.chinese).foregroundStyle(.primary)
                            Text(s.english).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(s.english).foregroundStyle(.primary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .accessibilityHint("填入搜索框")
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        .background(Color(.systemBackground))
    }

    /// 输入的是站内链接时直接打开
    private static func linkRoute(for text: String) -> Route? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("http") else { return nil }
        switch EhUrlRoute.parseEhUrl(t) {
        case let .galleryDetail(gid, token)?:
            return .galleryToken(gid: gid, token: token)
        case let .galleryList(builder)?:
            return .list(builder, title: nil)
        default:
            return nil
        }
    }
}

/// 搜索框获得焦点时把光标移到末尾。对应 Android `SearchBar.cursorToEnd`：
/// 搜索框里预先填好了当前条件（如标签），用户通常是在后面追加条件，而系统默认把光标放在点按的位置
enum SearchFieldCaret {
    @MainActor static func install() {
        NotificationCenter.default.addObserver(forName: UITextField.textDidBeginEditingNotification,
                                               object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let field = note.object as? UISearchTextField, !(field.text ?? "").isEmpty else { return }
                // 等系统按点按位置放好光标之后再移动
                DispatchQueue.main.async {
                    let end = field.endOfDocument
                    field.selectedTextRange = field.textRange(from: end, to: end)
                }
            }
        }
    }
}
