import SwiftUI
import EhCore
import EhNetwork

/// “我的”标签页：账号、额度、站点、My Tags、设置入口、Wi-Fi 互传、关于
struct MeTab: View {
    @Environment(AppModel.self) private var model
    @State private var path = NavigationPath()
    @State private var showSignIn = false
    @State private var limits = LimitsState()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                accountSection
                if model.isSignedIn && model.setting(\.showEhLimits) {
                    LimitsSection(state: limits)
                }
                siteSection
                if model.isSignedIn { accountFeatureSection }
                settingsSection
                otherSection
            }
            .navigationTitle("我的")
            .refreshable { await refresh() }
            .withAppRoutes()
        }
        .navigate(appendingTo: $path)
        .sheet(isPresented: $showSignIn) { SignInSheet() }
        .task(id: model.isSignedIn) {
            if model.isSignedIn {
                if model.displayName == nil { await model.fetchProfile() }
                await limits.load(model: model)
            } else {
                limits = LimitsState()
            }
        }
    }

    private func refresh() async {
        guard model.isSignedIn else { return }
        await model.fetchProfile()
        await limits.load(model: model)
    }

    // MARK: 账号卡片

    @ViewBuilder private var accountSection: some View {
        Section {
            if model.isSignedIn {
                NavigationLink {
                    AccountView()
                } label: {
                    accountCard(title: model.displayName ?? "已登录", subtitle: model.site.title)
                }
                .accessibilityHint("查看账号与身份 Cookie、退出登录")
            } else {
                Button {
                    showSignIn = true
                } label: {
                    accountCard(title: "登录", subtitle: "登录后可使用收藏、订阅、ExHentai 等功能", tinted: true)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func accountCard(title: String, subtitle: String, tinted: Bool = false) -> some View {
        HStack(spacing: 14) {
            AccountAvatar(size: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tinted ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    // MARK: 站点

    @ViewBuilder private var siteSection: some View {
        Section {
            Picker("站点", selection: model.siteBinding) {
                ForEach(EhSite.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } header: {
            Text("站点")
        } footer: {
            if model.site == .ex && !model.isSignedIn {
                Text("ExHentai 需要登录且账号拥有访问权限。")
            }
        }
    }

    // MARK: 账号功能

    @ViewBuilder private var accountFeatureSection: some View {
        Section {
            NavigationLink(value: Route.myTags) {
                SettingsIconLabel(title: "我的标签", systemImage: "tag", tint: .pink)
            }
            NavigationLink(value: Route.watched) {
                SettingsIconLabel(title: "订阅", systemImage: "eye", tint: .purple)
            }
        }
    }

    // MARK: 设置

    @ViewBuilder private var settingsSection: some View {
        Section("设置") {
            settingsLink(.eh)
            NavigationLink {
                AppearanceSettingsView()
            } label: {
                SettingsIconLabel(title: "外观", systemImage: "textformat.size", tint: .blue)
            }
            ForEach([SettingsPage.read, .download, .network, .privacy, .filter, .blackList, .advanced], id: \.self) { page in
                settingsLink(page)
            }
        }
    }

    private func settingsLink(_ page: SettingsPage) -> some View {
        NavigationLink(value: Route.settings(page)) {
            SettingsIconLabel(title: page.title, systemImage: page.systemImage, tint: page.tint)
        }
    }

    @ViewBuilder private var otherSection: some View {
        Section {
            NavigationLink(value: Route.transfer) {
                LabeledContent {
                    if let status = TransferViewModel.shared.activeSummary { Text(status) }
                } label: {
                    SettingsIconLabel(title: "Wi-Fi 互传", systemImage: "wifi", tint: .cyan)
                }
            }
            NavigationLink(value: Route.settings(.about)) {
                SettingsIconLabel(title: "关于", systemImage: "info.circle", tint: .gray)
            }
        }
    }
}

// MARK: - 额度

/// 图片额度（home.php）。对应 Android `LimitsCountView`
@MainActor @Observable
final class LimitsState {
    var detail: HomeDetail?
    var error: String?
    var loading = false
    var resetting = false

    func load(model: AppModel) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            detail = try await model.api.getHomeDetail()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func reset(model: AppModel) async {
        resetting = true
        defer { resetting = false }
        do {
            detail = try await model.api.resetLimit()
            model.toast.show("额度已重置", systemImage: "checkmark.circle")
        } catch {
            model.toast.error(error)
        }
    }
}

private struct LimitsSection: View {
    @Environment(AppModel.self) private var model
    let state: LimitsState
    @State private var confirmReset = false
    @State private var expanded = false

    var body: some View {
        Section {
            if let d = state.detail {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("图片额度").font(.subheadline)
                        Spacer()
                        Text(d.imageLimitsText(baseLimitsText: "IP 基础额度"))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(color(d))
                    }
                    if d.total > 0 {
                        ProgressView(value: Double(min(d.used, d.total)), total: Double(d.total))
                            .tint(color(d))
                    }
                }
                .padding(.vertical, 4)

                Button {
                    confirmReset = true
                } label: {
                    HStack {
                        Text("重置额度")
                        Spacer()
                        if state.resetting {
                            ProgressView()
                        } else {
                            Text(d.resetCostText).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(state.resetting || d.resetCost == 0 && d.used == 0)

                DisclosureGroup("GP 收入", isExpanded: $expanded) {
                    LabeledContent("画廊访问", value: d.fromGalleryVisitsText)
                    LabeledContent("种子完成", value: d.fromTorrentCompletionsText)
                    LabeledContent("归档下载", value: d.fromArchiveDownloadsText)
                    LabeledContent("Hentai@Home", value: d.fromHentaiAtHomeText)
                    LabeledContent("当前管理力", value: d.currentModerationPowerText)
                }
            } else if let error = state.error {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("重试") { Task { await state.load(model: model) } }
                }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        } header: {
            HStack {
                Text("额度")
                Spacer()
                if state.loading && state.detail != nil { ProgressView().controlSize(.mini) }
            }
        }
        .confirmationDialog("重置图片额度？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("重置（\(state.detail?.resetCostText ?? "")）", role: .destructive) {
                Task { await state.reset(model: model) }
            }
        } message: {
            Text("将消耗 GP 或 Credits 把已用额度清零。")
        }
    }

    private func color(_ d: HomeDetail) -> Color {
        guard d.total > 0 else { return .secondary }
        let r = Double(d.used) / Double(d.total)
        return r >= 0.9 ? .red : r >= 0.7 ? .orange : .green
    }
}
