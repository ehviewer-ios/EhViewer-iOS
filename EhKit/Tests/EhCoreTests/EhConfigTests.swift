import Testing
@testable import EhCore

@Suite struct EhConfigTests {
    @Test func defaultUconfig() {
        #expect(EhConfig().uconfig
            == "uh_y-xr_a-rx_0-ry_0-tl_r-ar_0-dm_l-prn_y-cats_0-fs_f-xns_0-xl_-rc_0-lt_m-ts_l-tr_2-cs_a-sc_0-to_a-pn_1-hp_-hk_-tf_n-oi_n-qb_n-ms_n-mt_n")
    }

    @Test func customUconfig() {
        var c = EhConfig()
        c.imageSize = EhConfig.imageSize1280x
        c.excludedLanguages = "1x1024x2048"
        c.defaultCategories = 0x3ff
        c.excludedNamespaces = EhConfig.namespacesReclass | EhConfig.namespacesMale
        c.hahClientIp = "192.168.1.2"
        c.hahClientPort = 8080
        c.hahClientPasskey = "key"
        let u = c.uconfig
        #expect(u.contains("-xr_1280-"))
        #expect(u.contains("-xl_1x1024x2048-"))
        #expect(u.contains("-cats_1023-"))
        #expect(u.contains("-xns_65-"))
        #expect(u.contains("-hp_192.168.1.2%3A8080-hk_key-"))
    }

    @Test func invalidHahClient() {
        var c = EhConfig()
        c.hahClientIp = "192.168.01.2"
        c.hahClientPort = 8080
        #expect(c.uconfig.contains("-hp_-"))
        c.hahClientIp = "1.2.3.4"
        c.hahClientPort = 70000
        #expect(c.uconfig.contains("-hp_-"))
    }

    @Test func inetValidator() {
        #expect(EhConfig.isValidInet4Address("0.0.0.0"))
        #expect(EhConfig.isValidInet4Address("255.255.255.255"))
        #expect(!EhConfig.isValidInet4Address("256.1.1.1"))
        #expect(!EhConfig.isValidInet4Address("1.2.3"))
        #expect(!EhConfig.isValidInet4Address(nil))
        #expect(EhConfig.isValidInetPort(0))
        #expect(!EhConfig.isValidInetPort(-1))
    }

    @Test func tipsCookie() {
        #expect(EhConfig.tipsCookie.name == "nw")
        #expect(EhConfig.tipsCookie.value == "1")
    }
}

@Suite struct EhCacheKeyFactoryTests {
    @Test func keys() {
        #expect(EhCacheKeyFactory.getThumbKey(123) == "preview:large:123:0")
        #expect(EhCacheKeyFactory.getNormalPreviewKey(123, 4) == "preview:normal:123:4")
        #expect(EhCacheKeyFactory.getLargePreviewKey(123, 4) == "preview:large:123:4")
        #expect(EhCacheKeyFactory.getLargePreviewSetKey(123, 4) == "large_preview_set:123:4")
        #expect(EhCacheKeyFactory.getImageKey(123, 4) == "image:123:4")
    }
}
