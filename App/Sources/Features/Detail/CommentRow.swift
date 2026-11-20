import SwiftUI
import EhCore

/// 单条评论。对应 Android `GalleryCommentsScene.ActualCommentHolder`
struct CommentRow<MenuContent: View>: View {
    let comment: GalleryComment
    /// 详情页摘要：限制行数、不显示投票按钮
    var compact = false
    /// 正在处理（例如拉取评论原文），在操作菜单位置显示进度
    var isBusy = false
    var onVote: ((Int) -> Void)?
    /// 行尾“更多”菜单内容（复制、编辑、投票详情、拉黑等）
    @ViewBuilder var menu: () -> MenuContent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if comment.isUploaderComment {
                    Text("上传者")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                }
                Text(comment.user ?? "匿名")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(CommentFormat.timeText(comment.time))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(CommentHTMLRenderer.render(comment.comment))
                .font(compact ? .subheadline : .body)
                .lineLimit(compact ? 4 : nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !compact {
                footer
            } else if !comment.isUploaderComment, comment.score != 0 {
                Text(CommentFormat.scoreText(comment.score)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
    }

    private var hasMenu: Bool { MenuContent.self != EmptyView.self }

    @ViewBuilder
    private var footer: some View {
        if !comment.isUploaderComment || comment.lastEdited != 0 || hasMenu {
            HStack(spacing: 4) {
                if comment.lastEdited != 0 {
                    Text("编辑于 \(CommentFormat.timeText(comment.lastEdited))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !comment.isUploaderComment {
                    if comment.voteUpAble || comment.voteUpEd {
                        Button { onVote?(1) } label: {
                            Image(systemName: comment.voteUpEd ? "hand.thumbsup.fill" : "hand.thumbsup")
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(comment.voteUpEd ? "取消赞" : "赞")
                    }
                    Text(CommentFormat.scoreText(comment.score))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(comment.score > 0 ? Color.green : (comment.score < 0 ? Color.red : Color.secondary))
                        .accessibilityLabel("得分 \(CommentFormat.scoreText(comment.score))")
                    if comment.voteDownAble || comment.voteDownEd {
                        Button { onVote?(-1) } label: {
                            Image(systemName: comment.voteDownEd ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(comment.voteDownEd ? "取消踩" : "踩")
                    }
                }
                if hasMenu {
                    if isBusy {
                        ProgressView()
                            .frame(minWidth: 44, minHeight: 44)
                    } else {
                        Menu(content: menu) {
                            Image(systemName: "ellipsis")
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("评论操作")
                    }
                }
            }
            .buttonStyle(.borderless)
            .font(.subheadline)
        }
    }

}

extension CommentRow where MenuContent == EmptyView {
    init(comment: GalleryComment, compact: Bool = false, onVote: ((Int) -> Void)? = nil) {
        self.init(comment: comment, compact: compact, onVote: onVote, menu: { EmptyView() })
    }
}

/// 评论文案工具（与菜单类型无关）
enum CommentFormat {
    static func scoreText(_ score: Int) -> String {
        score > 0 ? "+\(score)" : "\(score)"
    }

    static func timeText(_ ms: Int64) -> String {
        guard ms > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        if Date().timeIntervalSince(date) < 7 * 24 * 3600 {
            return date.formatted(.relative(presentation: .named))
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
