import Foundation
import Testing
@testable import EhNetwork

@Suite struct DNSMessageTests {
    @Test func encodeQueryA() throws {
        let q = try DNSMessage.encodeQuery(host: "e-hentai.org", type: .a)
        let expected: [UInt8] = [
            0, 0, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0,
            8, 0x65, 0x2d, 0x68, 0x65, 0x6e, 0x74, 0x61, 0x69, 3, 0x6f, 0x72, 0x67, 0,
            0, 1, 0, 1,
        ]
        #expect(q == expected)
    }

    @Test func encodeQueryAAAAUppercaseTrailingDot() throws {
        let q = try DNSMessage.encodeQuery(host: "EHGT.org.", type: .aaaa, id: 0x1234)
        #expect(Array(q[0..<2]) == [0x12, 0x34])
        #expect(Array(q[12...]) == [4, 0x65, 0x68, 0x67, 0x74, 3, 0x6f, 0x72, 0x67, 0, 0, 28, 0, 1])
    }

    @Test func encodeInvalidNames() {
        #expect(throws: DNSMessage.CodecError.self) { try DNSMessage.encodeQuery(host: "", type: .a) }
        #expect(throws: DNSMessage.CodecError.self) { try DNSMessage.encodeQuery(host: "a..b", type: .a) }
        #expect(throws: DNSMessage.CodecError.self) {
            try DNSMessage.encodeQuery(host: String(repeating: "x", count: 64) + ".org", type: .a)
        }
    }

    /// 构造：问题 www.example.org A；答案 CNAME(压缩指针) → example.org，A ×2，AAAA ×1
    static func sampleResponse() -> [UInt8] {
        var m: [UInt8] = [0xab, 0xcd, 0x81, 0x80, 0, 1, 0, 4, 0, 0, 0, 0]
        // question at offset 12
        m += [3] + Array("www".utf8) + [7] + Array("example".utf8) + [3] + Array("org".utf8) + [0, 0, 1, 0, 1]
        // CNAME: name ptr 12, type 5, class 1, ttl 300, rdata = ptr to "example.org" (offset 16)
        m += [0xc0, 12, 0, 5, 0, 1, 0, 0, 0x01, 0x2c, 0, 2, 0xc0, 16]
        // A example.org (ptr 16) ttl 120 1.2.3.4
        m += [0xc0, 16, 0, 1, 0, 1, 0, 0, 0, 120, 0, 4, 1, 2, 3, 4]
        // A ttl 60 5.6.7.8
        m += [0xc0, 16, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 5, 6, 7, 8]
        // AAAA ttl 600 2a00:7c80:0:123::3a85
        m += [0xc0, 16, 0, 28, 0, 1, 0, 0, 0x02, 0x58, 0, 16]
        m += [0x2a, 0x00, 0x7c, 0x80, 0, 0, 0x01, 0x23, 0, 0, 0, 0, 0, 0, 0x3a, 0x85]
        return m
    }

    @Test func decodeResponseWithCompression() throws {
        let r = try DNSMessage.decodeResponse(Self.sampleResponse(), expectedId: 0xabcd)
        #expect(r.id == 0xabcd)
        #expect(r.rcode == 0)
        #expect(r.isResponse)
        #expect(r.answers.count == 4)
        #expect(r.answers[0].name == "www.example.org")
        #expect(r.answers[0].type == 5)
        #expect(r.answers[1].name == "example.org")
        #expect(r.addresses.map(\.description) == ["1.2.3.4", "5.6.7.8", "2a00:7c80:0:123::3a85"])
        #expect(r.minimumTTL == 60)
    }

    @Test func decodeNXDomain() throws {
        var m: [UInt8] = [0, 0, 0x81, 0x83, 0, 1, 0, 0, 0, 0, 0, 0]
        m += [1, 0x61, 0, 0, 1, 0, 1]
        let r = try DNSMessage.decodeResponse(m)
        #expect(r.rcode == 3)
        #expect(r.addresses.isEmpty)
        #expect(r.minimumTTL == nil)
    }

    @Test func decodeErrors() {
        #expect(throws: DNSMessage.CodecError.truncated) { try DNSMessage.decodeResponse([0, 0, 0x81]) }
        // 不是响应
        #expect(throws: DNSMessage.CodecError.notResponse) {
            try DNSMessage.decodeResponse(try DNSMessage.encodeQuery(host: "a.org", type: .a))
        }
        #expect(throws: DNSMessage.CodecError.idMismatch) {
            try DNSMessage.decodeResponse(Self.sampleResponse(), expectedId: 1)
        }
        // 截断的答案
        let s = Self.sampleResponse()
        #expect(throws: DNSMessage.CodecError.self) { try DNSMessage.decodeResponse(Array(s.dropLast(5))) }
        // 指针环
        var loop: [UInt8] = [0, 0, 0x81, 0x80, 0, 1, 0, 0, 0, 0, 0, 0]
        loop += [0xc0, 12, 0, 1, 0, 1]
        #expect(throws: DNSMessage.CodecError.self) { try DNSMessage.decodeResponse(loop) }
    }

    @Test func base64URL() {
        #expect(DNSMessage.base64URL([0xfb, 0xff, 0xfe]) == "-__-")
        #expect(DNSMessage.base64URL([1]) == "AQ")
    }

    @Test func dohRequestShape() throws {
        let post = try DoHClient().makeRequest(host: "e-hentai.org", type: .a)
        #expect(post.url?.absoluteString == "https://77.88.8.1/dns-query")
        #expect(post.httpMethod == "POST")
        #expect(post.value(forHTTPHeaderField: "Content-Type") == "application/dns-message")
        #expect(post.value(forHTTPHeaderField: "Accept") == "application/dns-message")
        #expect(post.httpBody.map([UInt8].init) == (try DNSMessage.encodeQuery(host: "e-hentai.org", type: .a)))

        let get = try DoHClient(usePost: false).makeRequest(host: "e-hentai.org", type: .aaaa)
        #expect(get.httpMethod == "GET")
        let q = DNSMessage.base64URL(try DNSMessage.encodeQuery(host: "e-hentai.org", type: .aaaa))
        #expect(get.url?.absoluteString == "https://77.88.8.1/dns-query?dns=\(q)")
    }

    @Test func dohLookupMergesAAndAAAA() async throws {
        let sample = Self.sampleResponse()
        let client = DoHClient(fetch: { _ in (200, Data(sample)) })
        let r = try await client.lookup("www.example.org")
        // A、AAAA 两次查询都返回同一样本 → 6 个地址，IPv4 在前
        #expect(r.addresses.count == 6)
        #expect(r.addresses.first?.family == .v4)
        #expect(r.addresses.last?.family == .v6)
        #expect(r.ttl == 60)

        let failing = DoHClient(fetch: { _ in (500, Data()) })
        await #expect(throws: EhTransportError.self) { try await failing.lookup("x.org") }
    }

    @Test func ipAddressParsing() {
        #expect(EhIPAddress("104.20.18.168")?.bytes == [104, 20, 18, 168])
        #expect(EhIPAddress("[2a00:7c80:0:12d::38a1]")?.description == "2a00:7c80:0:12d::38a1")
        #expect(EhIPAddress("2a00:7c80:0:12d::38a1")?.urlHost == "[2a00:7c80:0:12d::38a1]")
        #expect(EhIPAddress("256.1.1.1") == nil)
        #expect(EhIPAddress("e-hentai.org") == nil)
        #expect(ehIsValidHost("e-hentai.org"))
        #expect(!ehIsValidHost("E-hentai.org"))
        #expect(!ehIsValidHost("a..b"))
    }
}
