import SwiftUI
import EhCore
import EhNetwork
import EhStorage

/// 全部评论。对应 Android `GalleryCommentsScene`
struct GalleryCommentsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.navigate) private var navigate
    @State private var vm: GalleryCommentsModel
    @State private var editor: CommentEditorRequest?
    @State private var voteStatus: CommentVoteStatus?
    @State private var blacklistTarget: GalleryComment?
    /// 正在拉取原文的评论（编辑前）
    @State private var fetchingEditId: Int64?
    @State private var showSignInPrompt = false
    @State private var showSignIn = false

    init(detail: GalleryDetail) {
        _vm = State(initialValue: GalleryCommentsModel(detail: detail))
    }

    var body: some View {
        content
            .navigationTitle("评论")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        guard model.isSignedIn else {
                            showSignInPrompt = true
                            return
                        }
                        editor = CommentEditorRequest(editId: nil, text: "")
                    } label: {
                        Label("发表评论", systemImage: "square.and.pencil")
                    }
                }
            }
            .refreshable { await vm.load(model) }
            .task { await vm.loadIfNeeded(model) }
            .environment(\.openURL, OpenURLAction { url in
                DetailLinkRouter.handle(url, app: model) { navigate($0) }
            })
            .sheet(item: $editor) { req in
                CommentEditorSheet(request: req) { text in
                    try await vm.post(text, editId: req.editId, model)
                }
            }
            .sheet(isPresented: $showSignIn) { SignInSheet() }
            .alert("需要登录", isPresented: $showSignInPrompt) {
                Button("登录") { showSignIn = true }
                Button("取消", role: .cancel) {}
            } message: {
                Text("登录后才能发表评论。")
            }
            .sheet(item: $voteStatus) { status in
                CommentVoteStatusSheet(status: status)
            }
            .confirmationDialog(
                "将“\(blacklistTarget?.user ?? "")”加入黑名单？",
                isPresented: Binding(get: { blacklistTarget != nil }, set: { if !$0 { blacklistTarget = nil } }),
                titleVisibility: .visible
            ) {
                Button("加入黑名单", role: .destructive) {
                    if let c = blacklistTarget { vm.blacklist(c, model) }
                }
            } message: {
                Text("此用户的评论将不再显示")
            }
    }

    @ViewBuilder
    private var content: some View {
        if vm.comments.isEmpty {
            if vm.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = vm.error {
                ErrorStateView(error: error) { Task { await vm.load(model) } }
            } else {
                ScrollView { EmptyStateView(title: "暂无评论", systemImage: "bubble.left.and.bubble.right").padding(.top, 80) }
            }
        } else {
            List {
                ForEach(vm.comments) { comment in
                    CommentRow(comment: comment, isBusy: fetchingEditId == comment.id, onVote: { vote in
                        Task { await vm.vote(comment, vote: vote, model) }
                    }, menu: {
                        menu(for: comment)
                    })
                    .padding(.vertical, 4)
                    .contextMenu { menu(for: comment) }
                }
                if vm.isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
                } else if vm.hasMore {
                    Button("加载全部评论") { Task { await vm.load(model) } }
                        .frame(maxWidth: .infinity)
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private func menu(for comment: GalleryComment) -> some View {
        Button { DetailClipboard.copy(CommentHTMLRenderer.plainText(comment.comment), model) } label: {
            Label("复制评论", systemImage: "doc.on.doc")
        }
        if let user = comment.user, !user.isEmpty {
            Button { DetailClipboard.copy(user, model) } label: { Label("复制用户名", systemImage: "person") }
        }
        if !comment.isUploaderComment {
            if comment.editable {
                Button {
                    fetchingEditId = comment.id
                    Task {
                        let text = await vm.fetchEditText(comment, model)
                        fetchingEditId = nil
                        if let text {
                            editor = CommentEditorRequest(editId: comment.id, text: text)
                        }
                    }
                } label: {
                    Label("编辑评论", systemImage: "pencil")
                }
                .disabled(fetchingEditId != nil)
            }
            if comment.voteUpAble || comment.voteUpEd {
                Button { Task { await vm.vote(comment, vote: 1, model) } } label: {
                    Label(comment.voteUpEd ? "取消赞" : "赞", systemImage: "hand.thumbsup")
                }
            }
            if comment.voteDownAble || comment.voteDownEd {
                Button { Task { await vm.vote(comment, vote: -1, model) } } label: {
                    Label(comment.voteDownEd ? "取消踩" : "踩", systemImage: "hand.thumbsdown")
                }
            }
            if let state = comment.voteState, !state.isEmpty {
                Button { voteStatus = CommentVoteStatus(raw: state, score: comment.score) } label: {
                    Label("查看投票详情", systemImage: "list.bullet")
                }
            }
        }
        if comment.user != nil {
            Button(role: .destructive) { blacklistTarget = comment } label: {
                Label("加入黑名单", systemImage: "person.crop.circle.badge.xmark")
            }
        }
    }
}

// MARK: - ViewModel

@MainActor @Observable
final class GalleryCommentsModel {
    private(set) var detail: GalleryDetail
    private(set) var comments: [GalleryComment]
    private(set) var hasMore: Bool
    private(set) var isLoading = false
    private(set) var error: Error?
    private var loaded = false

    init(detail: GalleryDetail) {
        self.detail = detail
        comments = detail.comments.comments
        hasMore = detail.comments.hasMore
    }

    private var canUseAPI: Bool { detail.apiUid >= 0 && !(detail.apiKey ?? "").isEmpty }

    func loadIfNeeded(_ app: AppModel) async {
        guard !loaded else { return }
        // 详情页已给出全部评论时不必再请求
        if !hasMore && !comments.isEmpty {
            loaded = true
            return
        }
        await load(app)
    }

    /// 对应 `RefreshCommentListener`：带 hc=1 重新请求详情页
    func load(_ app: AppModel) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let url = EhURL.galleryDetail(app.site, gid: detail.gid, token: detail.token, allComments: true)
            let d = try await app.api.getGalleryDetail(url: url)
            detail.apiUid = d.apiUid
            detail.apiKey = d.apiKey
            detail.comments = d.comments
            comments = d.comments.comments
            hasMore = false
            error = nil
            loaded = true
        } catch {
            if GalleryDetailModel.isCancellation(error) { return }
            if comments.isEmpty { self.error = error } else { app.toast.error(error) }
        }
    }

    /// vote：1 赞 / -1 踩（再次投同一票为取消）。对应 `voteComment` + `onVoteCommentSuccess`
    func vote(_ comment: GalleryComment, vote: Int, _ app: AppModel) async {
        guard canUseAPI else {
            app.toast.show("请先登录", systemImage: "person.crop.circle.badge.exclamationmark")
            return
        }
        do {
            let r = try await app.api.voteComment(apiUid: detail.apiUid, apiKey: detail.apiKey ?? "", gid: detail.gid,
                                                  token: detail.token, commentId: comment.id, commentVote: vote)
            guard let i = comments.firstIndex(where: { $0.id == r.id }) else { return }
            comments[i].score = r.score
            if r.expectVote > 0 {
                comments[i].voteUpEd = r.vote != 0
                comments[i].voteDownEd = false
            } else {
                comments[i].voteDownEd = r.vote != 0
                comments[i].voteUpEd = false
            }
            // 投票按钮与得分即结果，只给触感
            Haptics.success()
        } catch {
            if !GalleryDetailModel.isCancellation(error) {
                Haptics.error()
                app.toast.show("投票失败：\(error.localizedDescription)", systemImage: "exclamationmark.circle")
            }
        }
    }

    /// 发表（editId 为 nil）或编辑评论。成功后评论列表即结果，只给触感；失败抛出，由编辑器就地呈现
    func post(_ text: String, editId: Int64?, _ app: AppModel) async throws {
        let url = EhURL.galleryDetail(app.site, gid: detail.gid, token: detail.token)
        let list = try await app.api.commentGallery(url: url, comment: text, editId: editId.map { String($0) })
        comments = list.comments
        hasMore = list.hasMore
        detail.comments = list
        Haptics.success()
    }

    func fetchEditText(_ comment: GalleryComment, _ app: AppModel) async -> String? {
        guard canUseAPI else {
            app.toast.show("请先登录", systemImage: "person.crop.circle.badge.exclamationmark")
            return nil
        }
        do {
            let r = try await app.api.getEditComment(apiUid: detail.apiUid, apiKey: detail.apiKey ?? "", gid: detail.gid,
                                                     token: detail.token, commentId: comment.id)
            return r.comment
        } catch {
            if !GalleryDetailModel.isCancellation(error) {
                app.toast.show("获取评论原文失败：\(error.localizedDescription)", systemImage: "exclamationmark.circle")
            }
            return nil
        }
    }

    /// 对应 `EhDB.insertBlackList(BlackListUtils.parseBlacklist(comment))`
    func blacklist(_ comment: GalleryComment, _ app: AppModel) {
        guard let user = comment.user else { return }
        do {
            try app.filter.addToBlackList(BlackList.fromComment(user: user, comment: CommentHTMLRenderer.plainText(comment.comment)))
            comments.removeAll { $0.user == user }
            app.toast.show("已将 \(user) 加入黑名单", systemImage: "person.crop.circle.badge.xmark")
        } catch {
            app.toast.error(error)
        }
    }
}

// MARK: - 编辑器

struct CommentEditorRequest: Identifiable {
    let id = UUID()
    let editId: Int64?
    let text: String
}

struct CommentEditorSheet: View {
    let request: CommentEditorRequest
    let onSend: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var sending = false
    @State private var failure: String?
    @State private var confirmDiscard = false
    @FocusState private var focused: Bool

    private var isDirty: Bool {
        text != request.text && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 0) {
                        TextField("写下你的评论…", text: $text, axis: .vertical)
                            .focused($focused)
                            .disabled(sending)
                            .padding()
                        // 点输入框下方的空白处也能开始输入
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture { focused = true }
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()
                    Text("\(text.count) 字")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("已输入 \(text.count) 字")
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .navigationTitle(request.editId == nil ? "发表评论" : "编辑评论")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if isDirty { confirmDiscard = true } else { dismiss() }
                    }
                    .disabled(sending)
                    .confirmationDialog("放弃更改？", isPresented: $confirmDiscard, titleVisibility: .visible) {
                        Button("放弃更改", role: .destructive) { dismiss() }
                        Button("继续编辑", role: .cancel) {}
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else {
                        Button("发送") { send() }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .alert(request.editId == nil ? "评论发送失败" : "评论编辑失败",
                   isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(sending || isDirty)
        .onAppear {
            text = request.text
            focused = true
        }
    }

    private func send() {
        sending = true
        Task {
            do {
                try await onSend(text)
                sending = false
                dismiss()
            } catch {
                sending = false
                if !GalleryDetailModel.isCancellation(error) {
                    Haptics.error()
                    failure = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - 投票详情（对应 showVoteStatusDialog）

struct CommentVoteStatus: Identifiable {
    struct Entry: Hashable { let user: String; let vote: String }
    let id = UUID()
    let entries: [Entry]
    let score: Int

    init(raw: String, score: Int) {
        self.score = score
        entries = raw.split(separator: ",").map { part in
            let s = part.trimmingCharacters(in: .whitespaces)
            if let i = s.lastIndex(of: " ") {
                return Entry(user: s[..<i].trimmingCharacters(in: .whitespaces),
                             vote: s[s.index(after: i)...].trimmingCharacters(in: .whitespaces))
            }
            return Entry(user: s, vote: "")
        }
    }
}

struct CommentVoteStatusSheet: View {
    let status: CommentVoteStatus
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(status.entries, id: \.self) { e in
                LabeledContent(e.user) {
                    Text(e.vote)
                        .monospacedDigit()
                        .foregroundStyle(e.vote.hasPrefix("-") ? Color.red : Color.green)
                }
            }
            .navigationTitle("投票详情（\(CommentFormat.scoreText(status.score))）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
