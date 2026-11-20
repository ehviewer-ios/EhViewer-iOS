import Foundation

/// My Tags 中的一条用户标签。对应 Android `data/userTag/UserTag`
public struct UserTag: Codable, Sendable, Hashable {
    /// 元素 id，如 "usertag_3437"
    public var userTagId: String
    /// 完整标签名，如 "language:chinese"
    public var tagName: String?
    public var watched: Bool
    public var hidden: Bool
    /// 颜色（取自输入框 placeholder，如 "#default"）
    public var color: String?
    public var tagWeight: Int

    public init(
        userTagId: String, tagName: String? = nil, watched: Bool = false, hidden: Bool = false,
        color: String? = nil, tagWeight: Int = 0
    ) {
        self.userTagId = userTagId; self.tagName = tagName; self.watched = watched
        self.hidden = hidden; self.color = color; self.tagWeight = tagWeight
    }

    /// 数字 id。对应 `getId()`（userTagId.substring(8)）
    public var id: Int64 {
        let s = userTagId.count > 8 ? String(userTagId.dropFirst(8)) : ""
        return Int64(s) ?? 0
    }

    /// 显示名。对应 `getName(EhTagDatabase)`；`showTranslation` 对应 `Settings.getShowTagTranslations()`
    public func getName(_ ehTags: TagTranslation?, showTranslation: Bool) -> String? {
        if showTranslation, let name = tagName {
            let parts = TagTranslation.javaSplit(name, ":")
            if parts.count == 2 {
                return TagTranslation.getTagCN(parts, ehTags)
            }
        }
        return tagName
    }

    /// 删除该标签的表单体（application/x-www-form-urlencoded）。对应 `deleteParam()`
    public func deleteParam() -> String {
        "usertag_action=mass"
            + "&tagname_new="
            + "&tagcolor_new="
            + "&tagweight_new=\(tagWeight)"
            + "&modify_usertags%5B%5D=\(id)"
            + "&usertag_target=0"
    }
}

/// 用户标签列表。对应 `data/userTag/UserTagList`
public struct UserTagList: Codable, Sendable, Hashable {
    public var userTags: [UserTag]
    public var stageId: Int

    public init(userTags: [UserTag] = [], stageId: Int = 0) {
        self.userTags = userTags
        self.stageId = stageId
    }

    public func get(_ index: Int) -> UserTag { userTags[index] }
    public var size: Int { userTags.count }
}

/// 添加用户标签的参数。对应 `data/userTag/TagPushParam`
public struct TagPushParam: Codable, Sendable, Hashable {
    public var userTagAction: String?
    public var tagNameNew: String?
    /// "on" 表示勾选
    public var tagWatchNew: String?
    public var tagHiddenNew: String?
    public var tagColorNew: String?
    public var tagWeightNew: Int = 0
    public var userTagTarget: Int = 0

    public init(tagNameNew: String? = nil, tagWatchNew: String? = nil, tagHiddenNew: String? = nil, tagColorNew: String? = nil) {
        self.tagNameNew = tagNameNew
        self.tagWatchNew = tagWatchNew
        self.tagHiddenNew = tagHiddenNew
        self.tagColorNew = tagColorNew
    }

    /// 添加标签的表单体。对应 `addTagParam()`。
    /// 注意：Java 版 `getEncodeTagName` 调用 `String.replace` 却丢弃返回值，实际未编码；
    /// 这里做正确的表单编码（服务端解码结果一致，且 `&`、`+` 等字符不会出错）。
    /// watch 与 hide 同时为 "on" 时与 Java 一致，只发送 watch。
    public func addTagParam() -> String {
        var state = ""
        if tagHiddenNew == "on" {
            state = "&taghide_new=on"
        }
        if tagWatchNew == "on" {
            state = "&tagwatch_new=on"
        }
        return "usertag_action=add&tagname_new=" + Self.formEncode(tagNameNew ?? "")
            + state + "&tagcolor_new=" + Self.formEncode(tagColorNew ?? "")
            + "&tagweight_new=10&usertag_target=0"
    }

    /// application/x-www-form-urlencoded 编码（空格 -> "+"）
    static func formEncode(_ s: String) -> String {
        // 仅 ASCII 字母数字与 -._* 不编码（CharacterSet.alphanumerics 含非 ASCII 字母，不能用）
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._*")
        let encoded = s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
        return encoded.replacingOccurrences(of: "%20", with: "+")
    }
}
