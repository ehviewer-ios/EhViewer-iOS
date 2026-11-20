import SwiftUI
import EhStorage

/// 下载设置。对应 Android `DownloadFragment` / `download_settings.xml`
struct DownloadSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRedundancy = false
    @State private var confirmInvalid = false
    @State private var maintenanceRunning: String?
    @Environment(\.openURL) private var openURL
    @State private var labels: [String] = []
    @AppStorage(BackgroundDownloads.continuedEnabledKey) private var continueInBackground = true

    var body: some View {
        Form {
            locationSection

            Section("下载") {
                SettingsPicker("同时下载的图片数", selection: model.binding(\.multiThreadDownload),
                               options: EhSettings.multiThreadDownloadOptions) { "\($0)" }
                SettingsPicker("图片分辨率", selection: model.binding(\.imageResolution),
                               options: EhSettings.ImageResolution.options) { $0.title }
                Toggle("下载原图", isOn: model.binding(\.downloadOriginImage))
                SettingsPicker("超时", selection: model.binding(\.downloadTimeout),
                               options: EhSettings.downloadTimeoutOptions, style: .navigationLink) { $0 == 0 ? "默认" : "\($0) 秒" }
                labelPicker
            }

            if #available(iOS 26, *) {
                Section {
                    Toggle("切到后台后继续下载", isOn: $continueInBackground)
                        .onChange(of: continueInBackground) { _, on in
                            if !on { BackgroundDownloads.stopContinuedProcessing() }
                        }
                } footer: {
                    Text("下载时系统会显示进度，可以在锁屏或灵动岛上取消。低电量模式或系统资源紧张时可能提前停止，回到 App 后会继续下载。")
                }
            }

            Section {
                SettingsPicker("预加载页数", selection: model.binding(\.preloadImage),
                               options: EhSettings.preloadImageOptions, style: .navigationLink) { "\($0) 页" }
                Toggle("阅读时同步下载", isOn: model.binding(\.syncDownloadWhileReading))
            } header: {
                Text("阅读")
            } footer: {
                Text("“阅读时同步下载”：在线阅读已加入下载的画廊时，加载的图片同时写入下载目录。")
            }

            Section("列表") {
                Toggle("按时间升序排列", isOn: model.binding(\.downloadOrderAsc))
                Toggle("删除下载时同时删除图片", isOn: model.binding(\.removeImageFiles))
            }

            maintenanceSection
        }
        .navigationTitle("下载")
        .navigationBarTitleDisplayMode(.inline)
        .task { labels = (try? model.database.allDownloadLabels().compactMap(\.label)) ?? [] }
    }

    // MARK: 下载位置

    @ViewBuilder private var locationSection: some View {
        Section {
            LabeledContent("下载位置") { Text("文件 › 我的 \(UIDevice.current.model) › EhViewer › download") }
            if let dir = model.directories.defaultDownloadDir {
                Button {
                    openInFiles(dir)
                } label: {
                    Label("在“文件”中打开", systemImage: "folder")
                }
            }
        } footer: {
            Text("下载的内容可在“文件”App 中浏览、拷贝或删除。iOS 不支持更改下载位置。")
        }
    }

    /// 打开“文件”App 并定位到目录
    private func openInFiles(_ dir: URL) {
        var c = URLComponents(url: dir, resolvingAgainstBaseURL: false)
        c?.scheme = "shareddocuments"
        if let url = c?.url {
            openURL(url) { ok in
                if !ok { model.toast.show("无法打开“文件”App", systemImage: "exclamationmark.circle") }
            }
        }
    }

    // MARK: 默认标签

    private enum LabelChoice: Hashable {
        case ask
        case none
        case label(String)
    }

    @ViewBuilder private var labelPicker: some View {
        let binding = Binding<LabelChoice>(
            get: {
                _ = model.setting(\.hasDefaultDownloadLabel)
                guard model.settings.hasDefaultDownloadLabel else { return .ask }
                return model.settings.defaultDownloadLabel.map { .label($0) } ?? .none
            },
            set: { choice in
                switch choice {
                case .ask:
                    model.settings.hasDefaultDownloadLabel = false
                case .none:
                    model.settings.hasDefaultDownloadLabel = true
                    model.settings.defaultDownloadLabel = nil
                case let .label(l):
                    model.settings.hasDefaultDownloadLabel = true
                    model.settings.defaultDownloadLabel = l
                }
                model.settingsDidChange()
            }
        )
        Picker("默认下载标签", selection: binding) {
            Text("每次询问").tag(LabelChoice.ask)
            Text("默认").tag(LabelChoice.none)
            ForEach(labels, id: \.self) { Text($0).tag(LabelChoice.label($0)) }
        }
        .pickerStyle(.navigationLink)
    }

    // MARK: 维护

    @ViewBuilder private var maintenanceSection: some View {
        Section {
            Button("恢复下载项") { run("恢复下载项") { await restore() } }
            Button("清理冗余文件") { confirmRedundancy = true }
                .confirmationDialog("清理冗余文件？", isPresented: $confirmRedundancy,
                                    titleVisibility: .visible) {
                    Button("清理", role: .destructive) {
                        run("清理冗余文件") {
                            let n = await model.cleanRedundantDownloads()
                            return "已清理 \(n) 个文件夹"
                        }
                    }
                } message: {
                    Text("将删除下载目录中不属于任何下载项的文件夹。")
                }
            Button("清理无效下载") { confirmInvalid = true }
                .confirmationDialog("清理无效下载？", isPresented: $confirmInvalid,
                                    titleVisibility: .visible) {
                    Button("清理", role: .destructive) {
                        run("清理无效下载") {
                            let r = await model.cleanInvalidDownloads()
                            return r.count == 0 ? "没有发现无效下载" : "已清理 \(r.count) 个无效下载"
                        }
                    }
                } message: {
                    Text("将删除空的下载文件夹；已下载图片数与画廊页数不符的，会删除已下载的图片并重置为未下载。")
                }
            if let maintenanceRunning {
                HStack { ProgressView(); Text("正在\(maintenanceRunning)…").foregroundStyle(.secondary) }
            }
        } header: {
            Text("维护")
        } footer: {
            Text("恢复下载项：扫描下载目录，把不在列表中的画廊重新加入。\n清理冗余文件：删除下载目录中不属于任何下载项的文件夹。\n清理无效下载：删除空的下载文件夹；已下载图片数与画廊页数不符的，删除已下载的图片并重置为未下载。")
        }
    }

    private func restore() async -> String {
        guard let n = await model.restoreDownloadItems() else { return "下载目录不可用" }
        return n == 0 ? "没有找到可恢复的下载项" : "已恢复 \(n) 个下载项"
    }

    private func run(_ name: String, _ op: @escaping @MainActor () async -> String) {
        guard maintenanceRunning == nil else { return }
        maintenanceRunning = name
        Task {
            let msg = await op()
            maintenanceRunning = nil
            model.toast.show(msg, systemImage: "checkmark.circle")
        }
    }
}
