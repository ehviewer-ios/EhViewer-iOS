import SwiftUI
import UniformTypeIdentifiers
import EhStorage

/// 高级设置。对应 Android `AdvancedFragment` / `advanced_settings.xml`（网络相关项见 `NetworkSettingsView`）
struct AdvancedSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    @State private var cacheSize: Int64?
    @State private var confirmClearCache = false
    @State private var exportedFile: ExportedFile?
    @State private var exporting = false
    @State private var importKind: ImportKind = .database
    @State private var showImporter = false
    @State private var importing = false
    @State private var importResult: ImportResult?

    enum ImportKind: Identifiable {
        case database, androidPreferences
        var id: Self { self }
    }

    struct ExportedFile: Identifiable {
        let url: URL
        var id: URL { url }
    }

    struct ImportResult: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var body: some View {
        Form {
            cacheSection
            dataSection
            languageSection
            debugSection
        }
        .navigationTitle("高级")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshCacheSize() }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: importKind == .androidPreferences ? [.xml] : Self.databaseTypes) { result in
            switch result {
            case let .success(url):
                if importKind == .androidPreferences { importPreferences(url) } else { importDatabase(url) }
            case let .failure(error):
                model.toast.error(error)
            }
        }
        .alert(importResult?.title ?? "", isPresented: Binding(get: { importResult != nil }, set: { if !$0 { importResult = nil } }),
               presenting: importResult) { _ in
            Button("好") {}
        } message: { r in
            Text(r.message)
        }
        .sheet(item: $exportedFile) { file in
            ShareSheet(items: [file.url]) { exportedFile = nil }
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .confirmationDialog("清除缓存？", isPresented: $confirmClearCache, titleVisibility: .visible) {
            Button("清除缓存", role: .destructive) { clearCache() }
        } message: {
            Text("将删除缩略图与阅读图片缓存，不影响下载内容。")
        }
    }

    static var databaseTypes: [UTType] {
        var types: [UTType] = []
        if let db = UTType(filenameExtension: "db") { types.append(db) }
        types.append(.database)
        types.append(.data)
        return types
    }

    // MARK: 缓存

    @ViewBuilder private var cacheSection: some View {
        Section {
            SettingsPicker("阅读缓存上限", selection: model.binding(\.readCacheSize),
                           options: EhSettings.readCacheSizeOptions, style: .navigationLink) { "\($0) MB" }
            Button(role: .destructive) {
                confirmClearCache = true
            } label: {
                LabeledContent("清除缓存") {
                    if let cacheSize { Text(SettingsFormat.bytes(cacheSize)) } else { ProgressView() }
                }
            }
        } header: {
            Text("缓存")
        } footer: {
            Text("阅读缓存用于在线阅读时暂存图片，超过上限后自动淘汰最早的图片。")
        }
    }

    private func refreshCacheSize() async {
        let caches = model.directories.caches
        cacheSize = await Task.detached { SettingsFormat.directorySize(caches) }.value
    }

    private func clearCache() {
        AppImagePipeline.clearCaches()
        URLCache.shared.removeAllCachedResponses()
        let dirs = [model.directories.imageCacheDir, model.directories.thumbCacheDir, model.directories.tempDir,
                    model.directories.httpCacheDir].compactMap { $0 }
        cacheSize = nil
        Task {
            await Task.detached {
                let fm = FileManager.default
                for dir in dirs {
                    for item in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                        try? fm.removeItem(at: item)
                    }
                }
            }.value
            await refreshCacheSize()
            model.toast.show("缓存已清除", systemImage: "trash")
        }
    }

    // MARK: 调试

    @ViewBuilder private var debugSection: some View {
        Section {
            Toggle("保存解析错误页面", isOn: model.binding(\.saveParseErrorBody))
        } header: {
            Text("调试")
        } footer: {
            Text("页面解析失败时把 HTML 保存到 文件 › EhViewer › parse_error，便于反馈问题（7 天后自动删除）。")
        }
    }

    // MARK: 数据

    @ViewBuilder private var dataSection: some View {
        Section {
            Button {
                exportData()
            } label: {
                HStack {
                    Label("导出数据", systemImage: "square.and.arrow.up")
                    Spacer()
                    if exporting { ProgressView() }
                }
            }
            .disabled(exporting)
            Button {
                importKind = .database
                showImporter = true
            } label: {
                HStack {
                    Label("导入数据", systemImage: "square.and.arrow.down")
                    Spacer()
                    if importing { ProgressView() }
                }
            }
            .disabled(importing)
            Button {
                importKind = .androidPreferences
                showImporter = true
            } label: {
                Label("导入 Android 设置", systemImage: "gearshape.arrow.triangle.2.circlepath")
            }
        } header: {
            Text("数据")
        } footer: {
            Text("导出内容包括下载列表、历史、快速搜索、本地收藏、书签、过滤器、黑名单，与 Android 版 EhViewer 的导出文件兼容，可互相导入。导出的文件同时保存在 文件 › EhViewer › data。\n导入 Android 设置：选择 Android 端 shared_prefs 文件夹中的 com.xjs.ehviewer_preferences.xml。")
        }
    }

    private func exportData() {
        exporting = true
        let db = model.database
        let dir = model.directories.externalDataDir ?? FileManager.default.temporaryDirectory
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let url = dir.appendingPathComponent("EhViewer-\(f.string(from: Date())).db")
        Task {
            do {
                try await Task.detached { try db.exportDatabase(to: url, includeBlackListAndTags: true) }.value
                exportedFile = ExportedFile(url: url)
            } catch {
                model.toast.error(error)
            }
            exporting = false
        }
    }

    private func importDatabase(_ url: URL) {
        importing = true
        let db = model.database
        Task {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let s = try await Task.detached { try db.importDatabase(from: url) }.value
                try? model.filter.reload()
                model.downloads.reloadFromDatabase()
                importResult = ImportResult(title: "导入完成", message: Self.describe(s))
            } catch {
                importResult = ImportResult(title: "导入失败", message: error.localizedDescription)
            }
            importing = false
        }
    }

    static func describe(_ s: EhDatabase.ImportSummary) -> String {
        let rows: [(String, Int)] = [
            ("下载", s.downloads), ("下载标签", s.downloadLabels), ("下载目录名", s.downloadDirnames),
            ("历史", s.history), ("快速搜索", s.quickSearches), ("本地收藏", s.localFavorites),
            ("书签", s.bookmarks), ("过滤器", s.filters), ("黑名单", s.blackList), ("画廊标签", s.galleryTags),
        ]
        let text = rows.filter { $0.1 > 0 }.map { "\($0.0)：\($0.1)" }.joined(separator: "\n")
        return text.isEmpty ? "没有新增数据。" : text
    }

    private func importPreferences(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let n = try model.settings.importAndroidPreferences(xml: data)
            model.settingsDidChange(network: true)
            CustomHostsStore.apply(to: model)
            importResult = ImportResult(title: "导入完成", message: "已导入 \(n) 项设置。部分设置需要重启应用后生效。")
        } catch {
            importResult = ImportResult(title: "导入失败", message: error.localizedDescription)
        }
    }

    // MARK: 语言

    @ViewBuilder private var languageSection: some View {
        Section {
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                LabeledContent("应用语言") { Text("在系统设置中更改") }
            }
        } footer: {
            Text("iOS 在 设置 › EhViewer › 语言 中为单个应用切换语言。")
        }
    }
}

/// 系统分享面板（导出后直接弹出，不经过中间的 ShareLink 行）
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: () -> Void = {}

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        return vc
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
