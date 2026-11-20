import Foundation
import EhNetwork

/// 自定义 hosts 条目。对应 Android `Hosts`（SQLite 表 HOSTS(HOST, IP)）
struct CustomHost: Codable, Hashable, Identifiable {
    var host: String
    var ips: [String]
    var id: String { host }
}

/// 自定义 hosts 存储。
/// EhSettings / EhDatabase 暂无 hosts 存储，这里先用 UserDefaults（JSON）保存，
/// Core 可在 `AppModel.networkConfig(from:)` 中读取 `CustomHostsStore.table` 写入 `EhNetworkConfig.userHosts`。
enum CustomHostsStore {
    static let defaultsKey = "ehviewer_custom_hosts"

    static func load(_ defaults: UserDefaults = .standard) -> [CustomHost] {
        guard let data = defaults.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode([CustomHost].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [CustomHost], _ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    /// host → IP 列表（`EhNetworkConfig.userHosts` 的格式）
    static var table: [String: [String]] {
        var t: [String: [String]] = [:]
        for h in load() where !h.ips.isEmpty { t[h.host] = h.ips }
        return t
    }

    /// 校验并规范化 host（对应 `Hosts.isValidHost`，自动转小写）
    static func normalizeHost(_ s: String) -> String? {
        let h = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ehIsValidHost(h) ? h : nil
    }

    /// 解析 IP 列表（逗号 / 空格 / 换行分隔），任一无效返回 nil。对应 `Hosts.isValidIp`
    static func parseIPs(_ s: String) -> [String]? {
        let parts = s.split(whereSeparator: { $0 == "," || $0 == "，" || $0.isWhitespace }).map(String.init)
        guard !parts.isEmpty else { return nil }
        var out: [String] = []
        for p in parts {
            guard let ip = EhIPAddress(p) else { return nil }
            out.append(ip.description)
        }
        return out
    }

    /// 把当前列表应用到网络层（Core 接入 userHosts 前的临时做法）
    @MainActor
    static func apply(to model: AppModel) {
        let table = Self.table
        let http = model.http
        Task { await http.updateConfig { $0.userHosts = table } }
    }
}
