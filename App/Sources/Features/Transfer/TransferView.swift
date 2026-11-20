import SwiftUI
import CoreImage.CIFilterBuiltins
import VisionKit
import AVFoundation
import Network
import EhCore
import EhStorage
import EhTransfer

/// Wi-Fi 互传。对应 Android `ui/wifi/WiFiServerActivity`（发送）与 `WiFiClientActivity`（接收）。
///
/// 与 Android 互通（Android 端无二维码，接收端固定连接“DHCP 网关:54321”）：
/// - iOS → Android：iOS 打开“个人热点”，Android 连接该热点；iOS 选“发送”并开始，Android 点“接收”。
/// - Android → iOS：Android 发送端开热点，iOS 连接该热点后选“接收” › “连接 Android 热点”。
/// - iOS ↔ iOS：同一 Wi-Fi 下，发送端显示二维码，接收端扫码。
///
/// 会话由 `TransferViewModel.shared` 持有：离开本页不会断开，返回后可继续查看进度。
struct TransferView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @AppStorage("transfer_local_network_explained") private var localNetworkExplained = false
    @State private var showScanner = false
    @State private var manualAddress = ""
    @State private var confirmDisconnect = false
    @State private var showLocalNetworkInfo = false
    @State private var pendingAction: (() -> Void)?
    @State private var cameraAlert: CameraAlert?

    private var transfer: TransferViewModel { .shared }

    enum CameraAlert: Hashable {
        case unsupported, denied, restricted, unavailable

        var title: String {
            switch self {
            case .unsupported: return "此设备不支持扫码"
            case .denied, .restricted: return "无法使用相机"
            case .unavailable: return "相机暂不可用"
            }
        }

        var message: String {
            switch self {
            case .unsupported: return "请手动输入发送端显示的地址。"
            case .denied: return "请在“设置”中允许 EhViewer 使用相机来扫描二维码，或手动输入地址。"
            case .restricted: return "相机访问受到限制，请手动输入地址。"
            case .unavailable: return "请稍后重试，或手动输入地址。"
            }
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("角色", selection: Bindable(transfer).role) {
                    Text("发送").tag(TransferViewModel.Role.send)
                    Text("接收").tag(TransferViewModel.Role.receive)
                }
                .pickerStyle(.segmented)
                .disabled(transfer.isActive)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            switch transfer.role {
            case .send: senderSection
            case .receive: receiverSection
            }

            if transfer.isConnected { sendKindsSection }
            if let p = transfer.progress { progressSection(p) }
            if !transfer.log.isEmpty { logSection }
            helpSection
        }
        .navigationTitle("Wi-Fi 互传")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if transfer.isActive {
                ToolbarItem(placement: .primaryAction) {
                    Button("断开", role: .destructive) {
                        if transfer.isTransferring { confirmDisconnect = true } else { transfer.stop() }
                    }
                }
            }
        }
        .confirmationDialog("断开连接？", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("断开", role: .destructive) { transfer.stop() }
        } message: {
            Text("正在进行的传输会中断，已传完的内容会保留。")
        }
        .alert("允许访问本地网络", isPresented: $showLocalNetworkInfo) {
            Button("继续") {
                localNetworkExplained = true
                pendingAction?()
                pendingAction = nil
            }
            Button("取消", role: .cancel) { pendingAction = nil }
        } message: {
            Text("Wi-Fi 互传需要访问本地网络，才能与同一 Wi-Fi 或热点下的设备连接。系统询问时请选择“允许”。")
        }
        .alert("无法访问本地网络", isPresented: Bindable(transfer).localNetworkDenied) {
            Button("前往设置") { openSettings() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请在“设置”中打开 EhViewer 的“本地网络”权限，然后重试。")
        }
        .alert(cameraAlert?.title ?? "", isPresented: Binding(get: { cameraAlert != nil },
                                                              set: { if !$0 { cameraAlert = nil } }),
               presenting: cameraAlert) { kind in
            if kind == .denied {
                Button("前往设置") { openSettings() }
                Button("取消", role: .cancel) {}
            } else {
                Button("好", role: .cancel) {}
            }
        } message: { kind in
            Text(kind.message)
        }
        .sheet(isPresented: $showScanner) {
            QRScannerSheet { text in
                showScanner = false
                Task { await transfer.connect(model: model, address: text) }
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    /// 首次使用本地网络前先说明用途，再触发系统权限询问
    private func withLocalNetwork(_ action: @escaping () -> Void) {
        if localNetworkExplained {
            action()
        } else {
            pendingAction = action
            showLocalNetworkInfo = true
        }
    }

    // MARK: 发送端

    @ViewBuilder private var senderSection: some View {
        Section {
            if let info = transfer.serverInfo {
                VStack(spacing: 12) {
                    if let host = info.host {
                        if let qr = info.qrString, let image = QRCode.image(qr) {
                            Image(uiImage: image)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 220)
                                .padding(10)
                                .background(.white, in: RoundedRectangle(cornerRadius: 12))
                                .accessibilityLabel("连接二维码")
                                .accessibilityValue("地址 \(host):\(String(info.port))")
                        }
                        Text("\(host):\(String(info.port))")
                            .font(.title3.monospaced().weight(.semibold))
                            .textSelection(.enabled)
                    } else {
                        Label("未连接 Wi-Fi", systemImage: "wifi.slash")
                            .font(.title3.weight(.semibold))
                        Text("请连接 Wi-Fi 或打开个人热点，然后重新开始。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Text(transfer.statusText).font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                Button {
                    withLocalNetwork { Task { await transfer.startServer(model: model) } }
                } label: {
                    HStack {
                        Label("开始等待连接", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        if transfer.isBusy { ProgressView() }
                    }
                }
                .disabled(transfer.isBusy)
            }
        } header: {
            Text("发送")
        } footer: {
            Text("让接收端扫描二维码，或在接收端输入上面的地址。发送到 Android 时请先打开本机“个人热点”并让 Android 连接。")
        }
    }

    // MARK: 接收端

    @ViewBuilder private var receiverSection: some View {
        Section {
            if transfer.isActive {
                LabeledContent("状态") { Text(transfer.statusText) }
            } else {
                Button {
                    withLocalNetwork(startScanning)
                } label: {
                    Label("扫描二维码", systemImage: "qrcode.viewfinder")
                }
                HStack {
                    TextField("地址", text: $manualAddress, prompt: Text("如 192.168.1.5:54321"))
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(connectManual)
                    Button("连接", action: connectManual)
                        .disabled(manualAddress.trimmingCharacters(in: .whitespaces).isEmpty || transfer.isBusy)
                }
                Button {
                    withLocalNetwork { Task { await transfer.connectGateway(model: model) } }
                } label: {
                    HStack {
                        Label("连接 Android 热点", systemImage: "personalhotspot")
                        Spacer()
                        if transfer.isBusy {
                            ProgressView()
                        } else if let gw = LocalNetwork.gatewayGuess() {
                            Text(gw).font(.footnote.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(transfer.isBusy)
            }
        } header: {
            Text("接收")
        } footer: {
            Text("接收的数据会合并到本机：已存在的条目不会重复添加。")
        }
    }

    /// 扫码前检查相机：区分“设备不支持”与“权限被拒绝”
    private func startScanning() {
        guard DataScannerViewController.isSupported else {
            cameraAlert = .unsupported
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            if QRScannerSheet.isAvailable { showScanner = true } else { cameraAlert = .unavailable }
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                if !granted {
                    cameraAlert = .denied
                } else if QRScannerSheet.isAvailable {
                    showScanner = true
                } else {
                    cameraAlert = .unavailable
                }
            }
        case .denied:
            cameraAlert = .denied
        case .restricted:
            cameraAlert = .restricted
        @unknown default:
            cameraAlert = .unavailable
        }
    }

    private func connectManual() {
        let text = manualAddress.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        withLocalNetwork { Task { await transfer.connect(model: model, address: text) } }
    }

    // MARK: 发送数据选择

    @ViewBuilder private var sendKindsSection: some View {
        Section {
            ForEach(TransferDataKind.allCases, id: \.self) { kind in
                Toggle(kind.title, isOn: Binding(
                    get: { transfer.selectedKinds.contains(kind) },
                    set: { if $0 { transfer.selectedKinds.insert(kind) } else { transfer.selectedKinds.remove(kind) } }
                ))
                .disabled(transfer.isSending)
            }
            if transfer.isSending {
                Button("停止发送", role: .destructive) { Task { await transfer.cancelSending() } }
            } else {
                Button {
                    Task { await transfer.sendSelected() }
                } label: {
                    Label("发送所选数据", systemImage: "paperplane")
                }
                .disabled(transfer.selectedKinds.isEmpty)
            }
        } header: {
            Text(transfer.role == .send ? "要发送的数据" : "反向发送")
        } footer: {
            if transfer.role == .receive {
                Text("对端为 iOS 时可以反向发送；Android 发送端不会接收。")
            } else {
                Text("浏览历史仅 iOS 之间可迁移。下载文件会逐个校验，对端已有的文件自动跳过。")
            }
        }
    }

    // MARK: 进度与日志

    private func progressSection(_ p: TransferProgress) -> some View {
        Section("进度") {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(p.direction == .sending ? "正在发送" : "正在接收") \(p.kind.title)")
                    .font(.subheadline.weight(.medium))
                if p.total > 0 {
                    ProgressView(value: Double(min(p.current, p.total)), total: Double(p.total))
                    Text(p.kind == .downloadDir ? "目录 \(p.current)/\(p.total)" : "第 \(p.current)/\(p.total) 页")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let dir = p.dirname {
                    Text(dir).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if p.fileCount > 0 {
                    ProgressView(value: Double(min(p.fileIndex, p.fileCount)), total: Double(p.fileCount))
                        .tint(.green)
                    Text("文件 \(p.fileIndex)/\(p.fileCount)" + (p.skippedFiles > 0 ? "，跳过 \(p.skippedFiles)" : "")
                         + (p.bytes > 0 ? " · \(SettingsFormat.bytes(p.bytes))" : ""))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }

    private var logSection: some View {
        Section {
            ForEach(transfer.log.reversed()) { entry in
                Label {
                    Text(entry.message).font(.footnote)
                } icon: {
                    Image(systemName: entry.isError ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(entry.isError ? .red : .green)
                        .accessibilityLabel(entry.isError ? "错误" : "完成")
                }
            }
            Button("清除记录", role: .destructive) { transfer.log.removeAll() }
        } header: {
            Text("记录")
        }
    }

    private var helpSection: some View {
        Section("如何与 Android 互传") {
            VStack(alignment: .leading, spacing: 8) {
                Text("**iOS → Android**：打开本机“个人热点”，Android 连接该热点；本机选择“发送”并开始等待，Android 端进入“Wi-Fi 接收”。")
                Text("**Android → iOS**：Android 端进入“Wi-Fi 发送”并开启热点；本机连接该热点后，选择“接收” › “连接 Android 热点”。若连接失败，请在 Android 端查看热点地址后手动输入。")
                Text("**iOS ↔ iOS**：两台设备连接同一 Wi-Fi，接收端扫描发送端的二维码。")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 状态

@MainActor @Observable
final class TransferViewModel {
    /// 全局唯一的会话：离开互传页面不会断开
    static let shared = TransferViewModel()

    /// 接收下载数据后刷新下载列表用
    @ObservationIgnored private weak var app: AppModel?
    enum Role: Hashable { case send, receive }

    struct LogEntry: Identifiable {
        let id = UUID()
        let message: String
        var isError = false
    }

    var role: Role = .send
    private(set) var serverInfo: TransferServerInfo?
    private(set) var peer: String?
    private(set) var isBusy = false
    private(set) var isSending = false
    private(set) var progress: TransferProgress?
    var log: [LogEntry] = []
    var selectedKinds: Set<TransferDataKind> = [.quickSearch, .favorite, .download]

    private var server: TransferServer?
    private var client: TransferClient?
    private var eventTask: Task<Void, Never>?

    /// 本地网络权限被拒绝（用于提示前往设置）
    var localNetworkDenied = false

    var isConnected: Bool { peer != nil }
    var isActive: Bool { server != nil || client != nil }
    /// 正在发送或接收
    var isTransferring: Bool { isSending || progress != nil }

    /// “我的”页入口的状态摘要；未在使用时为 nil
    var activeSummary: String? {
        guard isActive else { return nil }
        if isTransferring { return "正在传输" }
        if isConnected { return "已连接" }
        return serverInfo != nil ? "等待连接" : nil
    }

    /// 连接失败是否因为本地网络权限被拒绝（NWConnection 进入 waiting，错误为 DNS PolicyDenied）
    nonisolated static func isLocalNetworkDenied(_ error: Error) -> Bool {
        if let nw = error as? NWError, case let .dns(code) = nw, code == -65570 { return true }
        let text = String(describing: error)
        return text.contains("PolicyDenied") || text.contains("-65570")
            || text.localizedCaseInsensitiveContains("local network")
    }

    var statusText: String {
        if let peer { return "已连接：\(peer)" }
        if serverInfo != nil { return "等待对端连接…" }
        if isBusy { return "正在连接…" }
        return "未连接"
    }

    private func makeSession(_ model: AppModel) -> TransferSession {
        app = model
        return TransferSession(database: model.database, directories: model.directories)
    }

    func startServer(model: AppModel) async {
        stop()
        isBusy = true
        defer { isBusy = false }
        let server = TransferServer(session: makeSession(model))
        self.server = server
        listen(server.events)
        do {
            serverInfo = try await server.start()
            if serverInfo?.host == nil {
                append("未找到可用的局域网地址，请连接 Wi-Fi 或打开个人热点", error: true)
            }
        } catch {
            if Self.isLocalNetworkDenied(error) { localNetworkDenied = true }
            append("启动失败：\(error.localizedDescription)", error: true)
            stop()
        }
    }

    func connect(model: AppModel, address: String) async {
        guard let (host, port) = TransferEndpoint.parse(address) else {
            append("无效的地址：\(address)", error: true)
            return
        }
        await connect(model: model) { try await $0.connect(host: host, port: port) }
    }

    func connectGateway(model: AppModel) async {
        await connect(model: model) { try await $0.connectToGateway() }
    }

    private func connect(model: AppModel, _ action: (TransferClient) async throws -> Void) async {
        stop()
        isBusy = true
        defer { isBusy = false }
        let client = TransferClient(session: makeSession(model))
        self.client = client
        listen(client.events)
        do {
            try await action(client)
            if peer == nil { peer = "已连接" }
        } catch {
            if Self.isLocalNetworkDenied(error) { localNetworkDenied = true }
            append("连接失败：\(error.localizedDescription)", error: true)
            stop()
        }
    }

    func sendSelected() async {
        let kinds = TransferDataKind.allCases.filter { selectedKinds.contains($0) }
        guard !kinds.isEmpty, !isSending else { return }
        isSending = true
        defer { isSending = false }
        for kind in kinds {
            do {
                if let server {
                    try await server.send(kind)
                } else if let client {
                    try await client.send(kind)
                } else {
                    return
                }
            } catch {
                let te = error as? TransferError
                if te == .cancelled {
                    append("已停止发送", error: true)
                    return
                }
                append("\(kind.title)发送失败：\(error.localizedDescription)", error: true)
                if te == .notConnected { return }
                if case .disconnected = te { return }
            }
        }
        progress = nil
    }

    func cancelSending() async {
        if let server { await server.cancelSending() }
        if let client { await client.cancelSending() }
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
        server?.stop()
        client?.disconnect()
        server = nil
        client = nil
        serverInfo = nil
        peer = nil
        progress = nil
        isSending = false
    }

    private func listen(_ events: AsyncStream<TransferEvent>) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await e in events {
                guard !Task.isCancelled else { break }
                self?.handle(e)
            }
        }
    }

    private func append(_ message: String, error: Bool = false) {
        log.append(LogEntry(message: message, isError: error))
        if log.count > 100 { log.removeFirst(log.count - 100) }
    }

    private func handle(_ e: TransferEvent) {
        switch e {
        case let .listening(info):
            serverInfo = info
        case let .connected(p):
            peer = p
            append("已连接 \(p)")
        case let .disconnected(reason):
            if peer != nil { append("连接已断开" + (reason.map { "：\($0)" } ?? ""), error: true) }
            peer = nil
            progress = nil
            if server == nil, client != nil {
                client?.disconnect()
                client = nil
            }
        case let .progress(p):
            progress = p
            if p.direction == .receiving, p.total > 0, p.current >= p.total, p.kind != .downloadDir {
                append("已接收\(p.kind.title)")
                if p.kind == .download { app?.downloads.reloadFromDatabase() }
            }
        case let .sendFinished(kind, s):
            var text = "已发送\(kind.title)：\(s.items) 条"
            if kind == .downloadDir {
                text = "已发送下载文件：\(s.pages) 个目录，\(s.files) 个文件（\(SettingsFormat.bytes(s.bytes))），跳过 \(s.skippedFiles)"
            }
            append(text)
            progress = nil
        case let .sendFailed(kind, msg):
            append("\(kind.title)发送失败：\(msg)", error: true)
        case let .unknownDataType(t):
            append("收到不支持的数据类型 \(t)", error: true)
        case let .fileChecksumFailed(gid, name):
            append("文件校验失败（\(gid)）：\(name)", error: true)
        case .downloadLocationUnavailable:
            append("本机下载目录不可用", error: true)
        case let .directoryCompleted(_, dirname):
            append("已接收目录：\(dirname)")
            app?.downloads.reloadFromDatabase()
        case let .spiderInfoInvalid(gid, dirname):
            append("目录缺少有效的 .ehviewer（\(gid)）：\(dirname)", error: true)
        case let .error(msg):
            append(msg, error: true)
        }
    }
}

extension TransferDataKind {
    var title: String {
        switch self {
        case .quickSearch: return "快速搜索"
        case .favorite: return "本地收藏"
        case .download: return "下载列表"
        case .downloadDir: return "下载文件"
        case .history: return "浏览历史"
        }
    }
}

// MARK: - 二维码

enum QRCode {
    static func image(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// 扫码（VisionKit DataScannerViewController）
struct QRScannerSheet: View {
    let onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @MainActor static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            QRScannerRepresentable(onScan: onScan)
                .ignoresSafeArea()
                .navigationTitle("扫描二维码")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                }
        }
    }
}

private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        if !vc.isScanning { try? vc.startScanning() }
    }

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) {
        vc.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        private var fired = false

        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !fired else { return }
            for item in addedItems {
                if case let .barcode(code) = item, let s = code.payloadStringValue,
                   TransferEndpoint.parse(s) != nil {
                    fired = true
                    dataScanner.stopScanning()
                    onScan(s)
                    return
                }
            }
        }
    }
}
