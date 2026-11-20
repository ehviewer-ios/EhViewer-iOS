import Testing
@testable import EhCore

@Suite struct LocalGallerySearchTests {
    private let item = LocalGallerySearch.Item(
        titles: ["[Artist] Re:Zero Book [Chinese] [汉化组]", "[アーティスト] リゼロ本"],
        uploader: "Some Uploader",
        label: "收藏",
        tags: ["language:chinese", "language:translated", "female:big breasts", "parody:re zero kara hajimeru isekai seikatsu", "lolicon"]
    )

    private func match(_ q: String) -> Bool { LocalGallerySearch(q).matches(item) }

    @Test func tokenize() {
        #expect(LocalGallerySearch.tokenize(#"f:"big breasts$"  l:chinese$"#) == [#"f:"big breasts$""#, "l:chinese$"])
        #expect(LocalGallerySearch.tokenize(#"-"a b" ~c"#) == [#"-"a b""#, "~c"])
        // 未闭合的引号到末尾为止（输入中）
        #expect(LocalGallerySearch.tokenize(#"f:"big br"#) == [#"f:"big br"#])
    }

    @Test func parse() {
        typealias C = LocalGallerySearch.Clause
        #expect(LocalGallerySearch(#"f:"big breasts$""#).clauses
            == [C(term: .tag(namespace: "female", name: "big breasts", exact: true))])
        #expect(LocalGallerySearch("-language:chinese").clauses
            == [C(term: .tag(namespace: "language", name: "chinese", exact: false), negated: true)])
        #expect(LocalGallerySearch(#"uploader:"Some Uploader""#).clauses == [C(term: .uploader("some uploader"))])
        // 无法识别的命名空间按普通词
        #expect(LocalGallerySearch("Re:Zero").clauses == [C(term: .text("re:zero", exact: false))])
        // 命名空间后没有值的忽略；单独的 - ~ 按普通词
        #expect(LocalGallerySearch("f: uploader:").isEmpty)
        #expect(LocalGallerySearch("-").clauses == [C(term: .text("-", exact: false))])
        #expect(LocalGallerySearch("   ").isEmpty)
    }

    @Test func tagMatching() {
        #expect(match(#"f:"big breasts$""#))
        #expect(match(#"female:"big breasts$""#))
        #expect(match("l:chinese$"))
        #expect(match(#"l:"chinese$" f:big"#))           // 标签建议补全 + 部分输入
        #expect(!match("f:big$"))                          // 精确匹配
        #expect(!match("male:big breasts"))                // 命名空间不同
        #expect(match(#"p:"re zero"#))                     // 未闭合引号（输入中）
        #expect(match("misc:lolicon$"))                    // 没有命名空间的标签
        #expect(match("lolicon$"))                         // 普通词精确匹配标签名
        #expect(!match("loli$"))
    }

    @Test func textMatching() {
        #expect(match("re:zero"))                          // 标题中的冒号
        #expect(match("リゼロ"))                            // 日文标题
        #expect(match("汉化组"))
        #expect(match("收藏"))                             // 下载标签
        #expect(match("uploader:some"))
        #expect(match("BIG"))                              // 不区分大小写，匹配标签名
        #expect(!match("naruto"))
    }

    @Test func operators() {
        #expect(!match("-l:chinese"))
        #expect(match("-l:english"))
        #expect(match("~l:english ~l:chinese"))
        #expect(!match("~l:english ~l:korean"))
        #expect(match("~l:english ~l:chinese f:big"))
        #expect(!match("~l:english ~l:chinese f:small"))
        #expect(match(""))
    }
}
