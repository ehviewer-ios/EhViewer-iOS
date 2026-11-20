import Foundation

/// 标签翻译库中的一条记录。对应 Android `client/data/Tag`
/// （不叫 `Tag` 以免与 Swift Testing 的 `Tag` 冲突）
public struct TranslatedTag: Codable, Sendable, Hashable {
    /// 英文标签，命名空间已展开为全称，如 "female:big breasts"
    public var english: String
    /// 中文翻译
    public var chinese: String

    public init(english: String, chinese: String) {
        self.english = english
        self.chinese = chinese
    }

    /// 对应 `Tag.involve`：英文或中文包含关键字
    public func involve(_ chars: String) -> Bool {
        english.contains(chars) || chinese.contains(chars)
    }
}

/// 搜索建议。对应 `suggest()` 返回的 `Pair<String, String>`（first = 中文, second = 英文）
public struct TagSuggestion: Sendable, Hashable {
    public var chinese: String
    public var english: String
    public init(chinese: String, english: String) {
        self.chinese = chinese
        self.english = english
    }
}

/// 标签中文翻译库。对应 Android `EhTagDatabase`（格式解析与查询部分） + `TagTranslationUtil`。
///
/// 文件格式：4 字节大端长度 N，随后 N 字节 UTF-8 文本；每行 `英文标签\rBase64(中文)\n`，
/// 按英文标签字节序升序排列（二分查找依赖此顺序）。英文标签使用短前缀，如 `f:big breasts`、`loc:beach`。
///
/// ## 下载与更新流程（网络部分不在 EhCore 中实现，由上层按以下步骤完成）
/// 对应 `EhTagDatabase.update(Context)`：
/// 1. 目录 `<Application Support>/tag-translations/`，文件名见 `Metadata.default`。
/// 2. 若本地 sha1 文件与数据文件校验失败（`TagTranslation.checkData(sha1:data:)`），删除两者。
/// 3. 若尚未加载且数据文件存在，`try TagTranslation(name:data:)` 加载；失败则删除两文件。
/// 4. 下载 `sha1Url` 到 `<sha1Name>.tmp`；失败则结束。
/// 5. 若新 sha1 与当前数据一致，删除临时 sha1，结束（数据无变化）。
/// 6. 下载 `dataUrl` 到 `<dataName>.tmp`；用新 sha1 校验新数据，不一致则删除两个临时文件并结束。
/// 7. 用临时文件替换正式文件，重新加载。
/// 整个过程应串行（Android 用 `ReentrantLock.tryLock`，正在更新时直接放弃本次更新）。
public struct TagTranslation: Sendable {

    /// 翻译数据源。对应 `res/values/arrays.xml` 的 `tag_translation_metadata`
    public struct Metadata: Sendable, Hashable {
        public var sha1Name: String
        public var sha1Url: String
        public var dataName: String
        public var dataUrl: String

        public init(sha1Name: String, sha1Url: String, dataName: String, dataUrl: String) {
            self.sha1Name = sha1Name
            self.sha1Url = sha1Url
            self.dataName = dataName
            self.dataUrl = dataUrl
        }

        public static let `default` = Metadata(
            sha1Name: "tag-translations-zh-rCN.sha1",
            sha1Url: "https://raw.githubusercontent.com/Mapaler/EhViewer/tag-translations/tag-translations/tag-translations-zh-rCN.sha1",
            dataName: "tag-translations-zh-rCN",
            dataUrl: "https://raw.githubusercontent.com/Mapaler/EhViewer/tag-translations/tag-translations/tag-translations-zh-rCN"
        )
    }

    public let name: String
    /// 原始行数据（不含 4 字节长度头），用于二分查找
    private let tags: [UInt8]
    /// 全部标签，用于模糊建议。对应 `getTagList()`
    public let tagList: [TranslatedTag]

    // MARK: 命名空间映射

    public static let namespaceToPrefixMap: [String: String] = [
        "rows": "n:",
        "artist": "a:",
        "cosplayer": "cos:",
        "character": "c:",
        "female": "f:",
        "group": "g:",
        "language": "l:",
        "location": "loc:",
        "male": "m:",
        "misc": "",
        "mixed": "x:",
        "other": "o:",
        "parody": "p:",
        "reclass": "r:",
    ]

    public static let prefixToNamespaceMap: [String: String] = [
        "n:": "rows",
        "a:": "artist",
        "cos:": "cosplayer",
        "c:": "character",
        "f:": "female",
        "g:": "group",
        "l:": "language",
        "loc:": "location",
        "m:": "male",
        "": "misc",
        "x:": "mixed",
        "o:": "other",
        "p:": "parody",
        "r:": "reclass",
    ]

    /// 对应 `namespaceToPrefix`：全称 -> 短前缀（带冒号）；若传入的本身就是短前缀（不带冒号）则原样返回
    public static func namespaceToPrefix(_ namespace: String) -> String? {
        if let prefix = namespaceToPrefixMap[namespace] {
            return prefix
        }
        if prefixToNamespaceMap[namespace + ":"] != nil {
            return namespace
        }
        return nil
    }

    /// 对应 `prefixToNamespace`：短前缀（带冒号）-> 全称
    public static func prefixToNamespace(_ prefix: String) -> String? {
        prefixToNamespaceMap[prefix]
    }

    // MARK: 加载

    /// 从数据文件内容构造。对应 `EhTagDatabase(String name, BufferedSource source)`
    /// - Parameter data: 完整文件内容（4 字节大端长度 + 正文）
    public init(name: String, data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else {
            throw EhError.parse("Tag translation data too short")
        }
        let total = Int(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        guard bytes.count - 4 >= total else {
            // 对应 readFully 的 EOFException
            throw EhError.parse("Tag translation data truncated")
        }
        let body = Array(bytes[4..<(4 + total)])
        self.name = name
        self.tags = body
        self.tagList = Self.initTagList(String(decoding: body, as: UTF8.self))
    }

    private static func initTagList(_ source: String) -> [TranslatedTag] {
        javaSplit(source, "\n").map(parseTag)
    }

    private static func parseTag(_ source: String) -> TranslatedTag {
        let cArray = javaSplit(source, "\r")
        if cArray.count == 2 {
            let chinese = decodeBase64(cArray[1]) ?? ""
            let eArray = javaSplit(cArray[0], ":")
            let english: String
            if eArray.count == 2 {
                let key = eArray[0] + ":"
                english = (prefixToNamespaceMap[key] ?? cArray[0]) + ":" + eArray[1]
            } else {
                english = cArray[0]
            }
            return TranslatedTag(english: english, chinese: chinese)
        }
        return TranslatedTag(english: source, chinese: "null")
    }

    // MARK: 查询

    /// 精确查询翻译，tag 使用短前缀形式（如 "f:big breasts"、"n:female"）。对应 `getTranslation`
    public func getTranslation(_ tag: String) -> String? {
        Self.search(tags, Array(tag.utf8))
    }

    /// 二分查找，逐字节对照 Java `search(byte[], byte[])`；越界时返回 nil（Java 会抛异常）
    private static func search(_ tags: [UInt8], _ tag: [UInt8]) -> String? {
        guard !tag.isEmpty, !tags.isEmpty else { return nil }
        let cr = UInt8(ascii: "\r"), lf = UInt8(ascii: "\n")
        var low = 0
        var high = tags.count
        while low < high {
            var start = (low + high) / 2
            // 向前找行首 '\n'
            while start > -1 && tags[start] != lf {
                start -= 1
            }
            start += 1

            // 找中间的 '\r'
            var middle = 1
            while true {
                guard start + middle < tags.count else { return nil }
                if tags[start + middle] == cr { break }
                middle += 1
            }

            // 找行尾 '\n'
            var end = middle + 1
            while true {
                guard start + end < tags.count else { return nil }
                if tags[start + end] == lf { break }
                end += 1
            }

            var compare = 0
            var tagIndex = 0
            var curIndex = start
            while true {
                let tagByte = Int(tag[tagIndex])
                let curByte = Int(tags[curIndex])
                compare = tagByte - curByte
                if compare != 0 { break }

                tagIndex += 1
                curIndex += 1
                if tagIndex == tag.count && curIndex == start + middle { break }
                if tagIndex == tag.count { compare = -1; break }
                if curIndex == start + middle { compare = 1; break }
            }

            if compare < 0 {
                high = start - 1
            } else if compare > 0 {
                low = start + end + 1
            } else {
                let b64 = String(decoding: tags[(start + middle + 1)..<(start + end)], as: UTF8.self)
                return decodeBase64(b64)
            }
        }
        return nil
    }

    /// 模糊建议：英文或中文包含 keyword，最多 40 条。对应 `suggest`
    public func suggest(_ keyword: String) -> [TagSuggestion] {
        var result: [TagSuggestion] = []
        for tag in tagList {
            if result.count >= 40 { break }
            if tag.involve(keyword) {
                result.append(TagSuggestion(chinese: tag.chinese, english: tag.english))
            }
        }
        return result
    }

    // MARK: TagTranslationUtil

    /// 对应 `TagTranslationUtil.getTagCN(String[], EhTagDatabase)`：
    /// "namespace:tag" -> "命名空间译名:标签译名"，缺失部分保留原文
    public static func getTagCN(_ tags: [String], _ db: TagTranslation?) -> String {
        if let db, tags.count == 2 {
            let namespace = prefixToNamespace(tags[0] + ":") ?? tags[0]
            let group = db.getTranslation("n:" + namespace)
            let tagStr = db.getTranslation(translationPrefix(tags[0]) + tags[1])
            return (group ?? tags[0]) + ":" + (tagStr ?? tags[1])
        }
        return tags.joined(separator: ":")
    }

    /// 对应 `TagTranslationUtil.getTagCN(String, EhTagDatabase)`
    public static func getTagCN(_ tag: String, _ db: TagTranslation?) -> String {
        getTagCN(javaSplit(tag, ":"), db)
    }

    /// 对应 `TagTranslationUtil.getTagCNBody`：只返回标签部分（不含命名空间）
    public static func getTagCNBody(_ tags: [String], _ db: TagTranslation?) -> String {
        if let db, tags.count == 2 {
            let tagStr = db.getTranslation(translationPrefix(tags[0]) + tags[1])
            return tagStr ?? tags[1]
        }
        // Java 实现的循环每次重建 StringBuffer，结果为最后一个元素
        return tags.last ?? ""
    }

    /// 全称（location）或短前缀（loc）-> 查询用前缀（"loc:"）
    private static func translationPrefix(_ namespaceOrPrefix: String) -> String {
        if prefixToNamespace(namespaceOrPrefix + ":") != nil {
            return namespaceOrPrefix + ":"
        }
        return namespaceToPrefix(namespaceOrPrefix) ?? ""
    }

    // MARK: 校验

    /// 对应 `checkData`：sha1 文件前 20 字节与数据文件的 SHA-1 摘要一致
    public static func checkData(sha1: Data, data: Data) -> Bool {
        guard sha1.count >= 20 else { return false }
        return Data(sha1.prefix(20)) == SHA1.hash(data)
    }

    // MARK: 工具

    /// Java `String.split(regex)` 语义（字面分隔符）：去掉末尾的空串
    static func javaSplit(_ s: String, _ sep: String) -> [String] {
        var parts = s.components(separatedBy: sep)
        while let last = parts.last, last.isEmpty {
            parts.removeLast()
        }
        // Java: "".split(x) 返回 [""]
        if parts.isEmpty { return s.isEmpty ? [""] : [] }
        return parts
    }

    /// 对应 Android `Base64.decode(DEFAULT)`：忽略空白、允许缺省填充
    static func decodeBase64(_ s: String) -> String? {
        var t = s.filter { !$0.isWhitespace }
        let rem = t.count % 4
        if rem != 0 { t += String(repeating: "=", count: 4 - rem) }
        guard let d = Data(base64Encoded: t) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }
}
