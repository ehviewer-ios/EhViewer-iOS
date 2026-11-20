import SwiftUI
import EhCore
import EhNetwork

/// 全部预览（分页加载 ?p=）。对应 Android `GalleryPreviewsScene`
struct GalleryPreviewsView: View {
    @Environment(AppModel.self) private var model
    @State private var vm: GalleryPreviewsModel
    @State private var showJump = false
    @State private var jumpText = ""

    init(detail: GalleryDetail) {
        _vm = State(initialValue: GalleryPreviewsModel(detail: detail))
    }

    var body: some View {
        ScrollView {
            if vm.firstPage > 0 {
                Button {
                    Task { await vm.loadPrevious(model) }
                } label: {
                    if vm.loadingPrevious {
                        ProgressView()
                    } else {
                        Label("加载上一页（第 \(vm.firstPage) 页）", systemImage: "arrow.up")
                    }
                }
                .buttonStyle(.bordered)
                .padding(.top, 8)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: vm.isLarge ? 140 : 96), spacing: 10)], spacing: 14) {
                ForEach(vm.items, id: \.position) { preview in
                    Button {
                        model.openReader(vm.detail.info, page: preview.position)
                    } label: {
                        DetailPreviewCell(preview: preview, referer: model.site.referer)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("第 \(preview.position + 1) 页")
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            footer.padding(.bottom, 20)
        }
        .navigationTitle(vm.totalPages > 0 ? "预览（\(vm.totalPages) 页）" : "预览")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    jumpText = ""
                    showJump = true
                } label: {
                    Label("跳页", systemImage: "arrow.right.to.line")
                }
                .disabled(vm.totalPages <= 1)
            }
        }
        .alert("跳转到预览页", isPresented: $showJump) {
            TextField("1 - \(vm.totalPages)", text: $jumpText)
                .keyboardType(.numberPad)
            Button("取消", role: .cancel) {}
            Button("跳转") {
                if let p = Int(jumpText), (1...max(vm.totalPages, 1)).contains(p) {
                    Task { await vm.jump(to: p - 1, model) }
                } else {
                    model.toast.show("页码无效", systemImage: "exclamationmark.circle")
                }
            }
        } message: {
            Text("共 \(vm.totalPages) 页")
        }
        .refreshable { await vm.jump(to: vm.firstPage, model) }
        .task { await vm.loadInitial(model) }
    }

    @ViewBuilder
    private var footer: some View {
        if vm.isLoading {
            ProgressView().padding()
        } else if let error = vm.error {
            VStack(spacing: 6) {
                Text(error.localizedDescription).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("重试") { Task { await vm.loadNext(model) } }.font(.footnote)
            }
            .padding()
        } else if vm.hasNext {
            Color.clear.frame(height: 1)
                .onAppear { Task { await vm.loadNext(model) } }
        } else if !vm.items.isEmpty {
            Text("没有更多了").font(.footnote).foregroundStyle(.tertiary).padding()
        } else {
            EmptyStateView(title: "没有预览", systemImage: "photo.on.rectangle")
        }
    }
}

/// 预览单元：缩略图 + 页码
struct DetailPreviewCell: View {
    let preview: GalleryPreview
    let referer: String

    var body: some View {
        VStack(spacing: 4) {
            PreviewThumbnail(preview: preview, referer: referer)
                .frame(maxWidth: .infinity)
                .frame(height: 140, alignment: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text("\(preview.position + 1)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(preview.position + 1) 页")
        .accessibilityAddTraits(.isImage)
    }
}

// MARK: - ViewModel

@MainActor @Observable
final class GalleryPreviewsModel {
    let detail: GalleryDetail
    /// 已加载的连续页范围 [firstPage, lastPage]
    private(set) var firstPage = 0
    private(set) var lastPage = -1
    private(set) var pages: [Int: [GalleryPreview]] = [:]
    private(set) var totalPages: Int
    private(set) var isLarge: Bool
    private(set) var isLoading = false
    private(set) var loadingPrevious = false
    private(set) var error: Error?

    init(detail: GalleryDetail) {
        self.detail = detail
        totalPages = detail.previewPages
        isLarge = detail.previewSet?.isLarge ?? false
        if let set = detail.previewSet, !set.isEmpty {
            pages[0] = set.items
            lastPage = 0
        }
    }

    var items: [GalleryPreview] {
        guard lastPage >= firstPage else { return [] }
        return (firstPage...lastPage).flatMap { pages[$0] ?? [] }
    }

    var hasNext: Bool { lastPage + 1 < totalPages || (lastPage < 0 && error == nil) }

    func loadInitial(_ app: AppModel) async {
        if lastPage < 0 { await loadNext(app) }
    }

    private func fetch(_ page: Int, _ app: AppModel) async throws -> [GalleryPreview] {
        let url = EhURL.galleryDetail(app.site, gid: detail.gid, token: detail.token, page: page)
        let r = try await app.api.getPreviewSet(url: url)
        if r.previewPages > 0 { totalPages = r.previewPages }
        isLarge = r.previewSet.isLarge
        return r.previewSet.items
    }

    func loadNext(_ app: AppModel) async {
        guard !isLoading else { return }
        let page = lastPage + 1
        guard totalPages == 0 || page < totalPages else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try await fetch(page, app)
            pages[page] = list
            lastPage = page
            error = nil
        } catch {
            if !GalleryDetailModel.isCancellation(error) { self.error = error }
        }
    }

    func loadPrevious(_ app: AppModel) async {
        guard !loadingPrevious, firstPage > 0 else { return }
        loadingPrevious = true
        defer { loadingPrevious = false }
        do {
            let page = firstPage - 1
            pages[page] = try await fetch(page, app)
            firstPage = page
        } catch {
            if !GalleryDetailModel.isCancellation(error) { app.toast.error(error) }
        }
    }

    /// 跳到指定页（从 0 开始），丢弃已加载范围
    func jump(to page: Int, _ app: AppModel) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try await fetch(page, app)
            pages = [page: list]
            firstPage = page
            lastPage = page
            error = nil
        } catch {
            if !GalleryDetailModel.isCancellation(error) { app.toast.error(error) }
        }
    }
}
