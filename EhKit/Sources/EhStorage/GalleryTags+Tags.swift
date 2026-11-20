import Foundation
import GRDB
import EhCore

extension GalleryTags {
    /// 命名空间 -> 列。与 Android `GalleryDetailTagsSyncTask.parserData` 一致
    static let columns: [(namespace: String, keyPath: WritableKeyPath<GalleryTags, String?>)] = [
        ("rows", \.rows), ("artist", \.artist), ("cosplayer", \.cosplayer), ("character", \.character),
        ("female", \.female), ("group", \.group), ("language", \.language), ("male", \.male),
        ("misc", \.misc), ("mixed", \.mixed), ("other", \.other), ("parody", \.parody),
        ("reclass", \.reclass), ("location", \.location),
    ]

    /// 由详情页的标签组生成。对应 `GalleryDetailTagsSyncTask.getTags`（同一列中的标签以逗号分隔）
    public init(gid: Int64, groups: [GalleryTagGroup]) {
        self.init(gid: gid)
        for group in groups {
            guard let column = Self.columns.first(where: { $0.namespace == group.groupName }) else { continue }
            let tags = group.tags.filter { !$0.isEmpty }
            self[keyPath: column.keyPath] = tags.isEmpty ? nil : tags.joined(separator: ",")
        }
    }

    /// 由带命名空间的标签生成（gdata 的 `tags`，如 `female:big breasts`；没有命名空间的归入 misc）
    public init(gid: Int64, namespacedTags: [String]) {
        var groups: [String: [String]] = [:]
        var order: [String] = []
        for raw in namespacedTags {
            let tag = raw.trimmingCharacters(in: .whitespaces)
            guard !tag.isEmpty else { continue }
            let (namespace, name): (String, String)
            if let colon = tag.firstIndex(of: ":") {
                namespace = String(tag[..<colon])
                name = String(tag[tag.index(after: colon)...])
            } else {
                namespace = "misc"
                name = tag
            }
            if groups[namespace] == nil { order.append(namespace) }
            groups[namespace, default: []].append(name)
        }
        self.init(gid: gid, groups: order.map { GalleryTagGroup(groupName: $0, tags: groups[$0] ?? []) })
    }

    /// 全部标签，带命名空间（如 `female:big breasts`）。对应 `DownloadListInfosExecutor.searchTagList`
    public var namespacedTags: [String] {
        Self.columns.flatMap { column -> [String] in
            guard let value = self[keyPath: column.keyPath] else { return [] }
            return value.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { "\(column.namespace):\($0)" }
        }
    }
}

extension EhDatabase {
    /// 写入或更新画廊标签（保留原 create_time）。对应 Android 打开详情页时的 `GalleryDetailTagsSyncTask`
    public func saveGalleryTags(_ tags: GalleryTags) throws {
        let date = Date(timeIntervalSince1970: Double(now()) / 1000)
        try dbQueue.write { db in
            var t = tags
            t.update_time = date
            if let existing = try GalleryTags.fetchOne(db, key: tags.gid) {
                t.create_time = existing.create_time ?? date
                try t.update(db)
            } else {
                t.create_time = date
                try t.insert(db)
            }
        }
    }

    /// 批量读取指定画廊的标签
    public func galleryTags(gids: [Int64]) throws -> [GalleryTags] {
        guard !gids.isEmpty else { return [] }
        return try dbQueue.read { db in try GalleryTags.fetchAll(db, keys: gids) }
    }
}
