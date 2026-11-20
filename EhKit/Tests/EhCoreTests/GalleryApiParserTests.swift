import Testing
@testable import EhCore

@Suite struct GalleryApiParserTests {
    static let body = #"""
    {"gmetadata":[
      {"gid":618395,"token":"0439fa3666","archiver_key":"x","title":"(Kouroumu 8) [Handful☆Happiness!] Touhou Tag Dream [English]",
       "title_jpn":"(紅楼夢8) [Handful☆Happiness!] 東方タッグドリーム","category":"Non-H",
       "thumb":"https://ehgt.org/14/63/1463dfbc16847c9ebef92c46a90e21ca881b2a12-1729712-4271-6032-jpg_l.jpg",
       "uploader":"avexotsukaai","posted":"1376143500","filecount":"20","filesize":51210504,"expunged":false,
       "rating":"4.43","torrentcount":"0","tags":["parody:touhou project","language:english"]},
      {"gid":2,"error":"Key missing, or incorrect key provided."},
      {"gid":999,"title":"not in list","title_jpn":"","category":"Manga","thumb":"","uploader":"u","posted":"0","filecount":"1","rating":"1","tags":[]}
    ]}
    """#

    @Test func fillsMatchingInfos() throws {
        var list = [GalleryInfo(gid: 618395, token: "0439fa3666"), GalleryInfo(gid: 2, token: "aaaaaaaaaa", title: "keep")]
        try GalleryApiParser.parse(Self.body, galleryInfoList: &list, thumbResolution: 1)
        let gi = list[0]
        #expect(gi.title == "(Kouroumu 8) [Handful☆Happiness!] Touhou Tag Dream [English]")
        #expect(gi.titleJpn == "(紅楼夢8) [Handful☆Happiness!] 東方タッグドリーム")
        #expect(gi.category == .nonH)
        #expect(gi.thumb == "https://ehgt.org/14/63/1463dfbc16847c9ebef92c46a90e21ca881b2a12-1729712-4271-6032-jpg_250.jpg")
        #expect(gi.uploader == "avexotsukaai")
        #expect(gi.posted == "2013-08-10 14:05")
        #expect(abs(gi.rating - 4.43) < 0.001)
        #expect(gi.pages == 20)
        #expect(gi.simpleTags == ["parody:touhou project", "language:english"])
        #expect(gi.simpleLanguage == "EN")
        // 带 error 的条目被跳过
        #expect(list[1].title == "keep")
        #expect(list.count == 2)
    }

    @Test func invalidJson() {
        var list: [GalleryInfo] = []
        #expect(throws: EhError.self) { try GalleryApiParser.parse("{}", galleryInfoList: &list) }
    }
}
