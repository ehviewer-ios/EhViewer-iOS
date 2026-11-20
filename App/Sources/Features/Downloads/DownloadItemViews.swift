import SwiftUI
import EhCore
import EhStorage
import EhSpider

/// 下载列表行：复用 GalleryRow，底部为状态 / 进度条 / 速度 / 标签；行尾为开始 / 暂停按钮（正常 HStack 布局，适配大字号）。
/// 点击行阅读，点击封面进入详情。对应 Android `DownloadAdapter`（详情模式）
struct DownloadItemRow: View {
    @Environment(AppModel.self) private var model
    let info: DownloadInfo
    var showsLabel: Bool
    var showsSize: Bool
    var fileSize: Int64?
    var isEditing: Bool
    /// 点击行（非编辑状态）
    var onOpen: () -> Void
    /// 点击封面：进入画廊详情（本地导入的项目没有详情，为 nil）。对应 Android `DownloadHolder` 点击 thumb
    var onOpenDetail: (() -> Void)? = nil
    var onStart: () -> Void
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if isEditing {
                rowContent
            } else {
                Button(action: onOpen) {
                    rowContent.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("download-item")
                .overlay(alignment: .topLeading) { coverButton }
                .accessibilityActions {
                    if let onOpenDetail { Button("查看详情", action: onOpenDetail) }
                }
                controlButton
            }
        }
    }

    private var thumbWidth: CGFloat { model.setting(\.detailSize) == .short ? 64 : 84 }

    /// 盖在封面上的透明按钮（与行按钮是兄弟视图，不嵌套）
    @ViewBuilder
    private var coverButton: some View {
        if let onOpenDetail {
            Button(action: onOpenDetail) {
                Color.clear
                    .frame(width: thumbWidth, height: thumbWidth / GalleryCellStyle.coverAspect)
                    .contentShape(Rectangle())
            }
            .buttonStyle(CoverPressStyle())
            // GalleryRow 的上内边距
            .padding(.top, 4)
            // VoiceOver 通过行上的“查看详情”操作
            .accessibilityHidden(true)
        }
    }

    private var rowContent: some View {
        GalleryRow(info: DownloadDisplay.galleryInfo(for: info, model: model), thumbWidth: thumbWidth) {
            VStack(alignment: .leading, spacing: 4) {
                if showsLabel, let label = info.label {
                    Label(label, systemImage: "tag")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DownloadProgressAccessory(info: info, showsSize: showsSize, fileSize: fileSize)
            }
        }
    }

    @ViewBuilder
    private var controlButton: some View {
        if DownloadDisplay.canStop(info) {
            DownloadControlButton(systemImage: "pause.circle.fill", title: "暂停", action: onStop)
        } else if DownloadDisplay.canStart(info) {
            DownloadControlButton(systemImage: "play.circle.fill", title: "开始", action: onStart)
        }
    }
}

/// 封面按钮按下时压暗封面
private struct CoverPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.black.opacity(configuration.isPressed ? 0.25 : 0))
        }
    }
}

/// 行内开始 / 暂停按钮：触控区不小于 44pt（触感由列表统一处理）
struct DownloadControlButton: View {
    let systemImage: String
    let title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(title))
    }
}

/// 状态文本 + 进度条 + 速度
struct DownloadProgressAccessory: View {
    let info: DownloadInfo
    var showsSize: Bool
    var fileSize: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // 大字号时状态与详情换行显示
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { stateLabel; detailLabel }
                VStack(alignment: .leading, spacing: 2) { stateLabel; detailLabel }
            }
            if showsProgress {
                if info.total > 0 {
                    ProgressView(value: Double(min(info.finished, info.total)), total: Double(info.total))
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
        }
    }

    private var stateLabel: some View {
        Text(DownloadDisplay.stateText(info))
            .font(.caption.weight(.medium))
            .foregroundStyle(DownloadDisplay.stateColor(info))
    }

    @ViewBuilder
    private var detailLabel: some View {
        if let detail = detailText {
            Text(detail)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var showsProgress: Bool {
        info.state == DownloadInfo.stateDownload
            || (info.state == DownloadInfo.stateWait && info.total > 0)
            || (info.state == DownloadInfo.stateFailed && info.total > 0)
    }

    private var detailText: String? {
        var parts: [String] = []
        switch info.state {
        case DownloadInfo.stateDownload:
            if info.total > 0 { parts.append("\(info.finished)/\(info.total)") }
            parts.append(DownloadDisplay.speedText(max(info.speed, 0)))
            if let r = DownloadDisplay.remainingText(info.remaining) { parts.append(r) }
        case DownloadInfo.stateWait, DownloadInfo.stateFailed, DownloadInfo.stateNone:
            if info.total > 0 { parts.append("\(info.finished)/\(info.total)") }
        case DownloadInfo.stateFinish:
            if showsSize {
                if info.total > 0 { parts.append("\(info.total) 页") }
                if let fileSize { parts.append(DownloadDisplay.byteText(fileSize)) }
            }
        default:
            break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 网格单元：复用 GalleryGridCell，封面底部叠加状态与进度条。对应 Android `DownloadAdapter`（缩略图模式）
struct DownloadGridItem: View {
    @Environment(AppModel.self) private var model
    let info: DownloadInfo

    var body: some View {
        GalleryGridCell(info: DownloadDisplay.galleryInfo(for: info, model: model)) {
            if info.state != DownloadInfo.stateFinish {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: symbol)
                        Text(shortText).lineLimit(1)
                    }
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    if info.state == DownloadInfo.stateDownload || info.total > 0 {
                        ProgressView(value: info.total > 0 ? Double(min(info.finished, info.total)) : 0,
                                     total: Double(max(info.total, 1)))
                            .tint(.white)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.55))
            }
        }
    }

    private var symbol: String {
        switch info.state {
        case DownloadInfo.stateDownload: return "arrow.down"
        case DownloadInfo.stateWait: return "clock"
        case DownloadInfo.stateFailed: return "exclamationmark.triangle"
        default: return "pause"
        }
    }

    private var shortText: String {
        if info.state == DownloadInfo.stateDownload {
            let progress = info.total > 0 ? "\(info.finished)/\(info.total) · " : ""
            return progress + DownloadDisplay.speedText(max(info.speed, 0))
        }
        return DownloadDisplay.stateText(info)
    }
}
