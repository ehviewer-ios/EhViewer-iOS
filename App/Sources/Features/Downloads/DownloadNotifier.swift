import Foundation
import UIKit
import UserNotifications
import EhStorage
import EhSpider

/// 下载完成通知。对应 Android `DownloadService` 的通知：
/// - 订阅 `DownloadManager.events` 与 `ArchiverDownloader.events`
/// - App 在前台时用 Toast，在后台时发本地通知（`UNUserNotificationCenter`）
/// - 首次有下载开始时请求通知权限
///
/// 接入：在 RootView 的 `.task { DownloadNotifier.shared.start(model) }` 调用一次（重复调用无副作用）。
/// 下载页出现时也会调用，作为未接入时的兜底。
@MainActor
final class DownloadNotifier {
    static let shared = DownloadNotifier()

    private var started = false
    private var authorizationRequested = false
    private var tasks: [Task<Void, Never>] = []
    private weak var model: AppModel?

    private init() {}

    func start(_ model: AppModel) {
        guard !started else { return }
        started = true
        self.model = model
        let downloadEvents = model.downloads.events
        let archiverEvents = model.archiver.events
        tasks.append(Task { [weak self] in
            for await event in downloadEvents {
                self?.handle(event)
            }
        })
        tasks.append(Task { [weak self] in
            for await event in archiverEvents {
                self?.handle(event)
            }
        })
    }

    /// 在用户主动开始下载时调用（按 HIG：在需要时、有上下文地请求权限）
    func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            }
        }
    }

    private var isActive: Bool {
        UIApplication.shared.applicationState == .active
    }

    private func title(_ info: DownloadInfo) -> String {
        model?.title(of: info.galleryInfo) ?? (info.title ?? "画廊 \(info.gid)")
    }

    private func handle(_ event: DownloadEvent) {
        guard let model else { return }
        switch event {
        case .started:
            break
        case let .finished(info):
            let ok = info.state == DownloadInfo.stateFinish
            let body = ok ? "下载完成：\(title(info))" : "下载失败：\(title(info))（\(info.legacy) 页未完成）"
            if isActive {
                model.toast.show(body, systemImage: ok ? "checkmark.circle" : "exclamationmark.circle")
            } else {
                post(id: "download-\(info.gid)", title: ok ? "下载完成" : "下载失败", body: title(info))
                if model.downloads.isIdle {
                    post(id: "download-all", title: "全部下载已结束", body: "下载队列已清空")
                }
            }
        case .got509:
            if isActive {
                model.toast.show("图片配额已用尽（509）", systemImage: "exclamationmark.triangle")
            } else {
                post(id: "download-509", title: "图片配额已用尽", body: "下载遇到 509 错误")
            }
        case .progress, .pageFinished, .cancelled:
            break
        }
    }

    private func handle(_ event: ArchiverEvent) {
        switch event {
        case .progress:
            break
        case let .imported(gid, _):
            if !isActive {
                let name = model?.downloads.downloadInfo(gid).map(title) ?? "画廊 \(gid)"
                post(id: "archive-\(gid)", title: "归档下载完成", body: name)
            }
        case let .failure(gid, _, error):
            if isActive {
                model?.toast.show("归档下载失败：\(error)", systemImage: "exclamationmark.circle")
            } else {
                post(id: "archive-\(gid)", title: "归档下载失败", body: error)
            }
        case .success, .cancelled:
            break
        }
    }

    private func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
