import Foundation

/// 自然排序。逐行对照 Android `com.hippo.util.NaturalComparator`：
/// 按 "." / " " / 数字串 / 其它串切片；数字串按数值比较（去前导零，相等时前导零多者在前），其它串忽略大小写比较。
public enum NaturalComparator {
    /// 返回 <0 / 0 / >0。nil 视为最小
    public static func compare(_ o1: String?, _ o2: String?) -> Int {
        guard let o1 else { return o2 == nil ? 0 : -1 }
        guard let o2 else { return 1 }
        // Java/Kotlin String 按 UTF-16 下标切片
        let s1 = Array(o1.utf16), s2 = Array(o2.utf16)
        var index1 = 0, index2 = 0
        while true {
            let data1 = nextSlice(s1, index1)
            let data2 = nextSlice(s2, index2)
            if data1 == nil, data2 == nil { return 0 }
            guard let data1 else { return -1 }
            guard let data2 else { return 1 }
            index1 += data1.count
            index2 += data2.count

            let result: Int
            if isDigit(data1.first!), isDigit(data2.first!) {
                result = compareNumberString(data1, data2)
            } else {
                result = compareIgnoreCase(data1, data2)
            }
            if result != 0 { return result }
        }
    }

    public static func areInIncreasingOrder(_ a: String, _ b: String) -> Bool {
        compare(a, b) < 0
    }

    private static let dot = UInt16(UInt8(ascii: ".")), space = UInt16(UInt8(ascii: " "))
    private static let zero = UInt16(UInt8(ascii: "0")), nine = UInt16(UInt8(ascii: "9"))

    private static func isDigit(_ ch: UInt16) -> Bool { ch >= zero && ch <= nine }

    private static func nextSlice(_ str: [UInt16], _ index: Int) -> ArraySlice<UInt16>? {
        if index == str.count { return nil }
        let ch = str[index]
        if ch == dot || ch == space { return str[index ..< index + 1] }
        var end = index + 1
        if isDigit(ch) {
            while end < str.count, isDigit(str[end]) { end += 1 }
        } else {
            while end < str.count, str[end] != dot, str[end] != space, !isDigit(str[end]) { end += 1 }
        }
        return str[index ..< end]
    }

    private static func removeLeadingZero(_ s: ArraySlice<UInt16>) -> ArraySlice<UInt16> {
        if s.isEmpty { return s }
        var i = s.startIndex
        let n = s.endIndex - 1
        while i < n {
            if s[i] != zero { return s[i...] }
            i += 1
        }
        return s[(s.endIndex - 1)...]
    }

    private static func compareNumberString(_ s1: ArraySlice<UInt16>, _ s2: ArraySlice<UInt16>) -> Int {
        let p1 = removeLeadingZero(s1), p2 = removeLeadingZero(s2)
        if p1.count > p2.count { return 1 }
        if p1.count < p2.count { return -1 }
        for (c1, c2) in zip(p1, p2) {
            if c1 > c2 { return 1 }
            if c1 < c2 { return -1 }
        }
        // 前导零多者在前
        return s1.count == s2.count ? 0 : (s1.count < s2.count ? 1 : -1)
    }

    /// Kotlin `compareTo(ignoreCase = true)`：逐字符比较 uppercase → lowercase
    private static func compareIgnoreCase(_ a: ArraySlice<UInt16>, _ b: ArraySlice<UInt16>) -> Int {
        func fold(_ c: UInt16) -> UInt16 {
            guard let scalar = Unicode.Scalar(c) else { return c }
            let up = String(scalar).uppercased()
            let low = up.lowercased()
            if low.utf16.count == 1 { return low.utf16.first! }
            return c
        }
        for (c1, c2) in zip(a, b) where c1 != c2 {
            let f1 = fold(c1), f2 = fold(c2)
            if f1 != f2 { return Int(f1) - Int(f2) }
        }
        return a.count - b.count
    }
}

/// 图片文件工具（扩展名判断、格式嗅探）。对应 `GalleryProvider2.SUPPORT_IMAGE_EXTENSIONS` 相关逻辑
public enum ImageFiles {
    /// 文件名（忽略大小写）是否以支持的图片扩展名结尾
    public static func isSupportedImageName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return SpiderNaming.supportImageExtensions.contains { lower.hasSuffix($0) }
    }

    /// 取扩展名（带点、小写）；不支持时回退 ".jpg"。对应 Archiver/Album 导入里的 `getImageExtension`
    public static func imageExtension(ofFilename name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return SpiderNaming.supportImageExtensions[0] }
        return SpiderNaming.fixExtension(String(name[dot...]).lowercased())
    }

    /// 由文件头嗅探图片格式，返回带点扩展名（未识别返回 nil）。替代 Android `BitmapFactory` 取 mime
    public static func sniffExtension(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return ".jpg" }
        if b.count >= 8, b[0 ..< 8] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return ".png" }
        if b.count >= 6, b[0 ..< 4] == [0x47, 0x49, 0x46, 0x38] { return ".gif" }
        if b.count >= 12, b[0 ..< 4] == [0x52, 0x49, 0x46, 0x46], b[8 ..< 12] == [0x57, 0x45, 0x42, 0x50] { return ".webp" }
        return nil
    }

    public static func sniffExtension(fileAt url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 16)) ?? Data()
        return sniffExtension(data)
    }

    /// 对应 SpiderQueen 的 "Check plain txt"：所有字节都 ≤ 126 视为文本（错误页而非图片）
    public static func isPlainText(fileAt url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? h.close() }
        while true {
            guard let chunk = try? h.read(upToCount: 64 * 1024), !chunk.isEmpty else { return true }
            if chunk.contains(where: { $0 > 126 }) { return false }
        }
    }

    /// 列出目录中的图片文件（不递归），按自然排序
    public static func listImages(in dir: URL, fileManager: FileManager = .default) -> [URL]? {
        guard isDirectory(dir, fileManager: fileManager),
              let names = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return nil }
        return names.filter { isSupportedImageName($0) && !$0.hasPrefix(".") }
            .filter { !isDirectory(dir.appendingPathComponent($0), fileManager: fileManager) }
            .sorted(by: NaturalComparator.areInIncreasingOrder)
            .map { dir.appendingPathComponent($0) }
    }

    public static func isDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    public static func isFile(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }

    static func fileSize(_ url: URL, fileManager: FileManager = .default) -> Int64 {
        ((try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
