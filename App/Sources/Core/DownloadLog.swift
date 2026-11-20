import Foundation

/// 下载诊断日志：Library/Caches/download.log，超过约 256 KB 时只保留后一半。记录：
/// - 切到前后台、持续处理任务的申请 / 开始 / 结束、后台时的下载进度（排查后台下载被系统停下的时机）
/// - 页最终失败的原因、被限流暂停、补下轮次、下载结束时的失败页（`SpiderEnvironment.diagnostics`）
/// 开发签名安装时可用 `xcrun devicectl device copy from --domain-type appDataContainer` 从设备取回。
enum DownloadLog {
    private static let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("download.log")
    private static let queue = DispatchQueue(label: "EhViewer.DownloadLog", qos: .utility)
    private static let limit = 256 * 1024

    static func write(_ message: String) {
        let line = "\(Date().formatted(Date.ISO8601FormatStyle(timeZone: .current))) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                let size = (try? handle.seekToEnd()) ?? 0
                if size > UInt64(limit), let old = try? Data(contentsOf: url) {
                    try? handle.truncate(atOffset: 0)
                    try? handle.write(contentsOf: old.suffix(limit / 2))
                }
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
