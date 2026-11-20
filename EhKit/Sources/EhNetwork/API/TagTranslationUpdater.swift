import Foundation

/// 标签翻译库的加载与下载更新。对应 Android `EhTagDatabase.getInstance / update(Context)`（网络与文件部分），
/// 数据格式解析由 `EhCore.TagTranslation` 完成。
///
/// 流程（与 Java 一致）：
/// 1. metadata 为 nil（当前语言无翻译）→ 清空实例并结束；当前实例名与 dataName 不同 → 清空实例
/// 2. 本地 sha1 与数据文件校验失败 → 删除两者
/// 3. 尚未加载且数据文件存在 → 加载；失败则删除两文件
/// 4. 下载 sha1 到 `<sha1Name>.tmp`；失败结束
/// 5. 新 sha1 与当前数据一致 → 删除临时 sha1，结束
/// 6. 下载数据到 `<dataName>.tmp`；用新 sha1 校验新数据，不一致则删除两临时文件并结束
/// 7. 临时文件替换正式文件并重新加载
/// 同一时刻只允许一个更新（对应 `ReentrantLock.tryLock`，正在更新时本次调用直接返回）。
public actor TagTranslationUpdater {
    public let client: EhHTTPClient
    /// 存放翻译文件的目录（对应 `AppConfig.getFilesDir("tag-translations")`），由调用方指定
    public let directory: URL
    /// nil 表示当前语言不支持（对应 `getMetadata` 返回 null）
    public let metadata: TagTranslation.Metadata?

    public private(set) var current: TagTranslation?
    private var updating = false

    public init(client: EhHTTPClient, directory: URL, metadata: TagTranslation.Metadata? = .default) {
        self.client = client
        self.directory = directory
        self.metadata = metadata
    }

    /// 对应 `getInstance`：返回已加载的实例；尚未加载时尝试从本地文件加载（不联网）
    public func instance() -> TagTranslation? {
        guard let metadata else {
            current = nil
            return nil
        }
        if current == nil, !updating {
            loadLocal(metadata)
        }
        return current
    }

    /// 执行一次更新，返回更新后（或未变化）的实例。正在更新时直接返回当前实例
    @discardableResult
    public func update() async -> TagTranslation? {
        guard let metadata else {
            current = nil
            return nil
        }
        if let c = current, c.name != metadata.dataName {
            current = nil
        }
        guard !updating else { return current }
        updating = true
        defer { updating = false }

        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        loadLocal(metadata)

        let sha1File = directory.appendingPathComponent(metadata.sha1Name)
        let dataFile = directory.appendingPathComponent(metadata.dataName)
        let tempSha1 = directory.appendingPathComponent(metadata.sha1Name + ".tmp")
        guard await save(metadata.sha1Url, to: tempSha1) else {
            try? fm.removeItem(at: tempSha1)
            return current
        }

        if Self.checkData(sha1File: tempSha1, dataFile: dataFile) {
            // 数据没有变化
            try? fm.removeItem(at: tempSha1)
            return current
        }

        let tempData = directory.appendingPathComponent(metadata.dataName + ".tmp")
        guard await save(metadata.dataUrl, to: tempData) else {
            try? fm.removeItem(at: tempData)
            return current
        }

        guard Self.checkData(sha1File: tempSha1, dataFile: tempData) else {
            try? fm.removeItem(at: tempSha1)
            try? fm.removeItem(at: tempData)
            return current
        }

        try? fm.removeItem(at: sha1File)
        try? fm.removeItem(at: dataFile)
        do {
            try fm.moveItem(at: tempSha1, to: sha1File)
            try fm.moveItem(at: tempData, to: dataFile)
        } catch {
            return current
        }

        if let data = try? Data(contentsOf: dataFile), let t = try? TagTranslation(name: metadata.dataName, data: data) {
            current = t
        }
        return current
    }

    /// 步骤 2、3：校验本地文件，必要时加载
    private func loadLocal(_ metadata: TagTranslation.Metadata) {
        let fm = FileManager.default
        let sha1File = directory.appendingPathComponent(metadata.sha1Name)
        let dataFile = directory.appendingPathComponent(metadata.dataName)
        if !Self.checkData(sha1File: sha1File, dataFile: dataFile) {
            try? fm.removeItem(at: sha1File)
            try? fm.removeItem(at: dataFile)
        }
        if current == nil, fm.fileExists(atPath: dataFile.path) {
            do {
                current = try TagTranslation(name: metadata.dataName, data: Data(contentsOf: dataFile))
            } catch {
                try? fm.removeItem(at: sha1File)
                try? fm.removeItem(at: dataFile)
            }
        }
    }

    /// 对应 `checkData(File, File)`：sha1 文件前 20 字节等于数据文件的 SHA-1
    static func checkData(sha1File: URL, dataFile: URL) -> Bool {
        guard let s = try? Data(contentsOf: sha1File), let d = try? Data(contentsOf: dataFile) else { return false }
        return TagTranslation.checkData(sha1: s, data: d)
    }

    /// 对应 `save(client, url, file)`：普通 GET（Java 用 `new Request.Builder()`，不带 EhRequestBuilder 的头），
    /// 非 2xx 或异常返回 false
    private func save(_ url: String, to file: URL) async -> Bool {
        guard let u = URL(string: url) else { return false }
        do {
            let resp = try await client.download(EhHTTPRequest(url: u), to: file, validate: false)
            return resp.isSuccess
        } catch {
            return false
        }
    }
}
