import Foundation

/// 站点：表站 e-hentai / 里站 exhentai。对应 Android `EhUrl.SITE_E / SITE_EX`。
public enum EhSite: Int, Codable, Sendable, CaseIterable {
    case e = 0
    case ex = 1

    public var domain: String { self == .e ? "e-hentai.org" : "exhentai.org" }
    public var host: String { "https://\(domain)/" }
    public var referer: String { "https://\(domain)" }
    public var origin: String { referer }
}

/// 画廊分类（位掩码，与站点 f_cats 参数一致）。对应 Android `EhConfig.MISC...WESTERN`、`EhUtils.UNKNOWN`。
public struct EhCategory: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let misc = EhCategory(rawValue: 0x1)
    public static let doujinshi = EhCategory(rawValue: 0x2)
    public static let manga = EhCategory(rawValue: 0x4)
    public static let artistCG = EhCategory(rawValue: 0x8)
    public static let gameCG = EhCategory(rawValue: 0x10)
    public static let imageSet = EhCategory(rawValue: 0x20)
    public static let cosplay = EhCategory(rawValue: 0x40)
    public static let asianPorn = EhCategory(rawValue: 0x80)
    public static let nonH = EhCategory(rawValue: 0x100)
    public static let western = EhCategory(rawValue: 0x200)
    public static let unknown = EhCategory(rawValue: 0x400)
    /// 对应 `EhUtils.NONE = -1`（首页）
    public static let none = EhCategory(rawValue: -1)
    public static let all = EhCategory(rawValue: 0x3ff)

    /// 单个分类，按站点展示顺序
    public static let ordered: [EhCategory] = [
        .doujinshi, .manga, .artistCG, .gameCG, .western, .nonH, .imageSet, .cosplay, .asianPorn, .misc,
    ]

    private static let table: [(EhCategory, [String])] = [
        (.misc, ["misc"]),
        (.doujinshi, ["doujinshi"]),
        (.manga, ["manga"]),
        (.artistCG, ["artistcg", "Artist CG Sets", "Artist CG"]),
        (.gameCG, ["gamecg", "Game CG Sets", "Game CG"]),
        (.imageSet, ["imageset", "Image Sets", "Image Set"]),
        (.cosplay, ["cosplay"]),
        (.asianPorn, ["asianporn", "Asian Porn"]),
        (.nonH, ["non-h"]),
        (.western, ["western"]),
    ]

    /// 对应 `EhUtils.getCategory(String)`
    public static func from(string: String?) -> EhCategory {
        guard let s = string else { return .unknown }
        for (cat, names) in table where names.contains(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) {
            return cat
        }
        return .unknown
    }

    /// 对应 `EhUtils.getCategory(int)`，返回站点使用的小写名
    public var siteName: String {
        Self.table.first(where: { $0.0 == self })?.1.first ?? "unknown"
    }

    /// 对应 `EhUtils.getCategoryColor`，ARGB
    public var colorARGB: UInt32 {
        switch self {
        case .doujinshi: return 0xFFF4_4336
        case .manga: return 0xFFFF_9800
        case .artistCG: return 0xFFFB_C02D
        case .gameCG: return 0xFF4C_AF50
        case .western: return 0xFF8B_C34A
        case .nonH: return 0xFF21_96F3
        case .imageSet: return 0xFF3F_51B5
        case .cosplay: return 0xFF9C_27B0
        case .asianPorn: return 0xFF95_75CD
        case .misc: return 0xFFF0_6292
        default: return 0xFF00_0000
        }
    }
}

/// 列表中的画廊条目。对应 Android `GalleryInfo`（去掉了 UI 专用的 span 字段之外全部保留）。
public struct GalleryInfo: Codable, Sendable, Hashable, Identifiable {
    public var gid: Int64
    public var token: String
    public var title: String?
    public var titleJpn: String?
    public var thumb: String?
    public var category: EhCategory
    public var posted: String?
    public var uploader: String?
    public var disowned: Bool
    public var rating: Float
    public var rated: Bool
    public var simpleTags: [String]?
    public var pages: Int
    public var thumbWidth: Int
    public var thumbHeight: Int
    public var simpleLanguage: String?
    /// -2 = 未知，-1 = 未收藏，0..9 = 收藏夹编号；对应 `favoriteSlot`
    public var favoriteSlot: Int
    public var favoriteName: String?
    /// 列表页的 tag 组（如 "f:big breasts"），对应 `tgList`
    public var tgList: [String]?

    public var id: Int64 { gid }

    public init(
        gid: Int64 = 0, token: String = "", title: String? = nil, titleJpn: String? = nil,
        thumb: String? = nil, category: EhCategory = .unknown, posted: String? = nil,
        uploader: String? = nil, disowned: Bool = false, rating: Float = 0, rated: Bool = false,
        simpleTags: [String]? = nil, pages: Int = 0, thumbWidth: Int = 0, thumbHeight: Int = 0,
        simpleLanguage: String? = nil, favoriteSlot: Int = -2, favoriteName: String? = nil,
        tgList: [String]? = nil
    ) {
        self.gid = gid; self.token = token; self.title = title; self.titleJpn = titleJpn
        self.thumb = thumb; self.category = category; self.posted = posted; self.uploader = uploader
        self.disowned = disowned; self.rating = rating; self.rated = rated; self.simpleTags = simpleTags
        self.pages = pages; self.thumbWidth = thumbWidth; self.thumbHeight = thumbHeight
        self.simpleLanguage = simpleLanguage; self.favoriteSlot = favoriteSlot
        self.favoriteName = favoriteName; self.tgList = tgList
    }

    // MARK: 语言推断（对应 generateSLang）

    public static let languages: [(code: String, tag: String, pattern: String)] = [
        ("EN", "language:english", #"[(\[]eng(?:lish)?[)\]]|英訳"#),
        ("ZH", "language:chinese", #"[(（\[]ch(?:inese)?[)）\]]|[汉漢]化|中[国國][语語]|中文|中国翻訳"#),
        ("ES", "language:spanish", #"[(\[]spanish[)\]]|[(\[]Español[)\]]|スペイン翻訳"#),
        ("KO", "language:korean", #"[(\[]korean?[)\]]|韓国翻訳"#),
        ("RU", "language:russian", #"[(\[]rus(?:sian)?[)\]]|ロシア翻訳"#),
        ("FR", "language:french", #"[(\[]fr(?:ench)?[)\]]|フランス翻訳"#),
        ("PT", "language:portuguese", #"[(\[]portuguese|ポルトガル翻訳"#),
        ("TH", "language:thai", #"[(\[]thai(?: ภาษาไทย)?[)\]]|แปลไทย|タイ翻訳"#),
        ("DE", "language:german", #"[(\[]german[)\]]|ドイツ翻訳"#),
        ("IT", "language:italian", #"[(\[]italiano?[)\]]|イタリア翻訳"#),
        ("VI", "language:vietnamese", #"[(\[]vietnamese(?: Tiếng Việt)?[)\]]|ベトナム翻訳"#),
        ("PL", "language:polish", #"[(\[]polish[)\]]|ポーランド翻訳"#),
        ("HU", "language:hungarian", #"[(\[]hun(?:garian)?[)\]]|ハンガリー翻訳"#),
        ("NL", "language:dutch", #"[(\[]dutch[)\]]|オランダ翻訳"#),
    ]

    private static let languageRegexes: [NSRegularExpression] = languages.map {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: $0.pattern, options: [.caseInsensitive])
    }

    public mutating func generateSimpleLanguage() {
        if let tags = simpleTags {
            for tag in tags {
                if let lang = Self.languages.first(where: { $0.tag == tag }) {
                    simpleLanguage = lang.code
                    return
                }
            }
        }
        if simpleLanguage == nil, let title {
            let range = NSRange(title.startIndex..., in: title)
            for (i, re) in Self.languageRegexes.enumerated() where re.firstMatch(in: title, range: range) != nil {
                simpleLanguage = Self.languages[i].code
                return
            }
            simpleLanguage = nil
        }
    }

    /// 对应 `EhUtils.getSuitableTitle`
    public func suitableTitle(preferJapanese: Bool) -> String {
        if preferJapanese {
            return (titleJpn?.isEmpty == false ? titleJpn : title) ?? ""
        }
        return (title?.isEmpty == false ? title : titleJpn) ?? ""
    }
}
