import Testing
@testable import EhCore

@Suite struct EhUtilsTests {
    @Test func extractTitle() {
        #expect(EhUtils.extractTitle("(C91) [Aoirokanata (Shikitani Asuka)] Neko Flan to Kainushi Koishi | 貓芙蘭和飼主戀 (Touhou Project) [Chinese] [魔恋汉化组]")
            == "Neko Flan to Kainushi Koishi ")
        #expect(EhUtils.extractTitle("[Artist] Some Title ch. 1-23 [English] {Team}") == "Some Title")
        #expect(EhUtils.extractTitle("~foo~ Title (bar)") == "Title")
        #expect(EhUtils.extractTitle("[only brackets]") == nil)
        #expect(EhUtils.extractTitle(nil) == nil)
    }

    @Test func thumbResolution() {
        let url = "https://ehgt.org/dc/ad/dcad-753622-2150-3035-jpg_250.jpg"
        #expect(EhUtils.handleThumbUrlResolution(url, resolution: 0) == url)
        #expect(EhUtils.handleThumbUrlResolution(url, resolution: 1) == url)
        #expect(EhUtils.handleThumbUrlResolution(url, resolution: 2) == "https://ehgt.org/dc/ad/dcad-753622-2150-3035-jpg_300.jpg")
        #expect(EhUtils.handleThumbUrlResolution("https://a/b.jpg", resolution: 2) == "https://a/b.jpg")
        #expect(EhUtils.handleThumbUrlResolution(nil, resolution: 2) == nil)
    }

    @Test func categories() {
        #expect(EhUtils.getCategory("Game CG") == EhCategory.gameCG.rawValue)
        #expect(EhUtils.getCategory("whatever") == EhUtils.UNKNOWN)
        #expect(EhUtils.getCategory(EhCategory.nonH.rawValue) == "non-h")
        #expect(EhUtils.ALL_CATEGORY == 0x3ff)
    }

    @Test func titles() {
        let gi = GalleryInfo(title: "en", titleJpn: "")
        #expect(EhUtils.getSuitableTitle(gi, showJpnTitle: true) == "en")
        #expect(EhUtils.getSuitableTitle(GalleryInfo(title: "en", titleJpn: "jp"), showJpnTitle: true) == "jp")
        #expect(EhUtils.judgeSuitableTitle(GalleryInfo(title: "abc", titleJpn: "日本"), key: "本ab"))
    }

    @Test func urlCoding() {
        #expect(EhUtils.urlEncode("a b:c/中*.-_~") == "a+b%3Ac%2F%E4%B8%AD*.-_%7E")
        #expect(EhUtils.urlDecode("a+b%3Ac%2F%E4%B8%AD") == "a b:c/中")
        #expect(EhUtils.urlDecode("%zz") == nil)
    }
}
