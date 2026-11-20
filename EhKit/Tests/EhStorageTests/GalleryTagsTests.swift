import Foundation
import Testing
import EhCore
@testable import EhStorage

@Suite struct GalleryTagsTests {
    @Test func fromGroups() {
        let t = GalleryTags(gid: 1, groups: [
            GalleryTagGroup(groupName: "language", tags: ["chinese", "translated"]),
            GalleryTagGroup(groupName: "female", tags: ["big breasts"]),
            GalleryTagGroup(groupName: "unknown", tags: ["x"]),
        ])
        #expect(t.language == "chinese,translated")
        #expect(t.female == "big breasts")
        #expect(t.namespacedTags == ["female:big breasts", "language:chinese", "language:translated"])
    }

    @Test func fromNamespacedTags() {
        let t = GalleryTags(gid: 2, namespacedTags: ["language:chinese", "female:big breasts", "lolicon", "other:full color"])
        #expect(t.language == "chinese")
        #expect(t.misc == "lolicon")
        #expect(t.other == "full color")
        #expect(Set(t.namespacedTags) == ["language:chinese", "female:big breasts", "misc:lolicon", "other:full color"])
    }

    @Test func saveKeepsCreateTime() throws {
        let db = try makeDB()
        try db.saveGalleryTags(GalleryTags(gid: 3, namespacedTags: ["language:chinese"]))
        let first = try #require(try db.queryGalleryTags(gid: 3))
        try db.saveGalleryTags(GalleryTags(gid: 3, namespacedTags: ["language:english"]))
        let second = try #require(try db.queryGalleryTags(gid: 3))
        #expect(second.language == "english")
        #expect(second.create_time == first.create_time)
        #expect(second.update_time! > first.update_time!)
        #expect(try db.galleryTags(gids: [3, 4]).map(\.gid) == [3])
    }
}
