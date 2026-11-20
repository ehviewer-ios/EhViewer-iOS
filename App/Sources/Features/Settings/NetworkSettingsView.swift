import SwiftUI
import EhNetwork
import EhStorage

/// 网络设置（Android 高级设置中的网络相关项）。修改后 `settingsDidChange(network: true)` 重建网络配置
struct NetworkSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var proxyHost = ""
    @State private var proxyPort = ""
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                Toggle("域前置", isOn: networkBinding(\.domainFronting))
            } footer: {
                Text("直连站点 IP 并省略 TLS SNI，可在部分受限网络下访问。使用 VPN 或显式代理时自动停用。")
            }

            Section {
                Toggle("内置 hosts（E-Hentai）", isOn: networkBinding(\.builtInHosts))
                Toggle("内置 hosts（ExHentai）", isOn: networkBinding(\.builtExHosts))
                NavigationLink {
                    CustomHostsView()
                } label: {
                    LabeledContent("自定义 hosts") { Text("\(CustomHostsStore.load().count) 条") }
                }
                Toggle("DNS over HTTPS", isOn: networkBinding(\.doH))
            } header: {
                Text("域名解析")
            } footer: {
                Text("解析顺序：自定义 hosts → 内置 hosts → DoH / 系统 DNS。")
            }

            proxySection
        }
        .navigationTitle("网络")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            proxyHost = model.settings.proxyIp ?? ""
            let p = model.settings.proxyPort
            proxyPort = p > 0 ? String(p) : ""
        }
    }

    /// 网络相关设置：保存后重建网络配置，并重新应用自定义 hosts
    private func networkBinding<T>(_ keyPath: ReferenceWritableKeyPath<EhSettings, T>) -> Binding<T> {
        let b = model.binding(keyPath, network: true)
        return Binding(get: { b.wrappedValue }, set: {
            b.wrappedValue = $0
            CustomHostsStore.apply(to: model)
        })
    }

    // MARK: 代理

    @ViewBuilder private var proxySection: some View {
        let type = model.setting(\.proxyType)
        Section {
            Picker("代理", selection: networkBinding(\.proxyType)) {
                ForEach(EhSettings.ProxyType.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if type == .http || type == .socks {
                TextField("地址", text: $proxyHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("端口", text: $proxyPort)
                    .keyboardType(.numberPad)
                Button("保存代理设置") { saveProxy() }
                    .disabled(!proxyChanged)
            }
        } header: {
            Text("代理")
        } footer: {
            if type == .http || type == .socks {
                Text("地址或端口无效时回落为系统代理。使用代理时不启用域前置。")
            } else {
                Text("“系统代理”跟随 iOS 设置中的 Wi-Fi 代理与 VPN 配置。")
            }
        }
    }

    private var proxyChanged: Bool {
        _ = model.setting(\.proxyIp)
        let p = model.settings.proxyPort
        return proxyHost != (model.settings.proxyIp ?? "") || proxyPort != (p > 0 ? String(p) : "")
    }

    private func saveProxy() {
        let host = proxyHost.trimmingCharacters(in: .whitespaces)
        let port = Int(proxyPort.trimmingCharacters(in: .whitespaces)) ?? -1
        if !host.isEmpty, !(1...65535).contains(port) {
            model.toast.show("端口应为 1–65535", systemImage: "exclamationmark.circle")
            return
        }
        model.settings.proxyIp = host.isEmpty ? nil : host
        model.settings.proxyPort = port
        model.settingsDidChange(network: true)
        CustomHostsStore.apply(to: model)
        model.toast.show("代理设置已保存", systemImage: "checkmark.circle")
    }
}

/// 自定义 hosts 编辑。对应 Android `HostsActivity`
struct CustomHostsView: View {
    @Environment(AppModel.self) private var model
    @State private var hosts: [CustomHost] = []
    @State private var editing: CustomHost?
    @State private var adding = false

    var body: some View {
        List {
            if hosts.isEmpty {
                Section {
                    Text("暂无自定义 hosts").foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(hosts) { h in
                    Button {
                        editing = h
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.host).foregroundStyle(.primary)
                            Text(h.ips.joined(separator: ", "))
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { idx in
                    hosts.remove(atOffsets: idx)
                    persist()
                }
            } footer: {
                if !hosts.isEmpty { Text("自定义 hosts 优先于内置 hosts 与 DNS。") }
            }
        }
        .navigationTitle("自定义 hosts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Label("添加", systemImage: "plus") }
            }
            if !hosts.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
        .sheet(isPresented: $adding) {
            HostEditSheet(original: nil) { upsert($0, replacing: nil) }
        }
        .sheet(item: $editing) { h in
            HostEditSheet(original: h) { upsert($0, replacing: h) }
        }
        .onAppear { hosts = CustomHostsStore.load() }
    }

    private func upsert(_ h: CustomHost, replacing old: CustomHost?) {
        if let old { hosts.removeAll { $0.host == old.host } }
        if let i = hosts.firstIndex(where: { $0.host == h.host }) {
            hosts[i] = h
        } else {
            hosts.append(h)
        }
        persist()
    }

    private func persist() {
        CustomHostsStore.save(hosts)
        CustomHostsStore.apply(to: model)
    }
}

private struct HostEditSheet: View {
    let original: CustomHost?
    let onSave: (CustomHost) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var ips = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("域名，如 e-hentai.org", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("IP，多个用逗号分隔", text: $ips, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(original == nil ? "添加 hosts" : "编辑 hosts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
            .onAppear {
                if let original {
                    host = original.host
                    ips = original.ips.joined(separator: ", ")
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard let h = CustomHostsStore.normalizeHost(host) else {
            error = "无效的域名"
            return
        }
        guard let list = CustomHostsStore.parseIPs(ips) else {
            error = "无效的 IP 地址"
            return
        }
        onSave(CustomHost(host: h, ips: list))
        dismiss()
    }
}
