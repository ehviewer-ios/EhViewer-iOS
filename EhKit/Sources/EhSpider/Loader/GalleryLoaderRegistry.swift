import Foundation

/// 按 gid 共享 `GalleryLoader` 并引用计数。对应 `SpiderQueen.obtainSpiderQueen / releaseSpiderQueen`（sQueenMap）。
///
/// - 阅读器：`obtain(info, mode: .read)`，关闭时 `loader.close()` 或 `release(loader, mode: .read)`
/// - 下载：`obtainWithEvents(info, mode: .download)`（先订阅事件再切换模式，避免漏掉事件），结束时 `release(loader, mode: .download)`
/// - 读、下载引用都归零时停止并移除
public actor GalleryLoaderRegistry {
    private var loaders: [Int64: GalleryLoader] = [:]
    public private(set) var environment: SpiderEnvironment
    /// 自定义构造（测试用）
    private let factory: (@Sendable (GalleryInfo, SpiderEnvironment, GalleryLoaderRegistry) -> GalleryLoader)?

    public init(environment: SpiderEnvironment) {
        self.environment = environment
        factory = nil
    }

    init(environment: SpiderEnvironment,
         factory: @escaping @Sendable (GalleryInfo, SpiderEnvironment, GalleryLoaderRegistry) -> GalleryLoader) {
        self.environment = environment
        self.factory = factory
    }

    /// 更新设置 / 依赖。只影响之后新建的加载器（与 Android 每次新建 SpiderQueen 时读设置一致）
    public func updateEnvironment(_ transform: @Sendable (inout SpiderEnvironment) -> Void) {
        transform(&environment)
    }

    private func loaderForObtain(_ info: GalleryInfo) -> (GalleryLoader, isNew: Bool) {
        if let l = loaders[info.gid] { return (l, false) }
        let l = factory?(info, environment, self) ?? GalleryLoader(galleryInfo: info, environment: environment, registry: self)
        loaders[info.gid] = l
        return (l, true)
    }

    /// 获取（必要时创建并启动）加载器，并增加 mode 引用
    public func obtain(_ info: GalleryInfo, mode: LoaderMode) async -> GalleryLoader {
        let (loader, isNew) = loaderForObtain(info)
        await loader.retain(mode)
        if isNew { await loader.start() }
        return loader
    }

    /// 同 `obtain`，但在切换模式之前订阅事件
    public func obtainWithEvents(_ info: GalleryInfo, mode: LoaderMode) async -> (GalleryLoader, AsyncStream<LoaderEvent>) {
        let (loader, isNew) = loaderForObtain(info)
        let stream = loader.events
        await loader.retain(mode)
        if isNew { await loader.start() }
        return (loader, stream)
    }

    /// 释放 mode 引用；无引用时停止并移除
    public func release(_ loader: GalleryLoader, mode: LoaderMode) async {
        guard loaders[loader.gid] === loader else {
            // 已被移除（重复释放）
            return
        }
        if await loader.release(mode) {
            // release 期间可能有新的 obtain，再确认一次
            let refs = await loader.referenceCount
            if refs.read == 0, refs.download == 0, loaders[loader.gid] === loader {
                loaders.removeValue(forKey: loader.gid)
                await loader.stop()
            }
        }
    }

    public func loader(gid: Int64) -> GalleryLoader? { loaders[gid] }

    public var activeCount: Int { loaders.count }

    /// 对应 `SpiderQueen.resetReadingProgress`
    public func resetReadingProgress(gid: Int64) async {
        await loaders[gid]?.resetReadingProgress()
    }
}
