import Foundation
import Testing
@testable import EhNetwork

@Suite struct HTTP1Tests {
    func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// 把字节按 step 切片喂给解析器，收集事件
    func run(_ raw: [UInt8], step: Int, method: HTTPMethod = .get, eof: Bool = false)
        throws -> (head: HTTPResponseHead?, body: [UInt8], ended: Bool, parser: HTTP1ResponseParser) {
        var p = HTTP1ResponseParser(requestMethod: method)
        var head: HTTPResponseHead?
        var body: [UInt8] = []
        var ended = false
        func handle(_ evs: [HTTP1ResponseParser.Event]) {
            for e in evs {
                switch e {
                case let .head(h): head = h
                case let .body(d): body += [UInt8](d)
                case .end: ended = true
                }
            }
        }
        var i = 0
        while i < raw.count {
            let j = min(raw.count, i + step)
            handle(try p.feed(bytes: Array(raw[i..<j])))
            i = j
        }
        if eof { handle(try p.finish()) }
        return (head, body, ended, p)
    }

    @Test func serializeRequest() {
        var h = HTTPHeaders()
        h.add("User-Agent", "UA")
        h.add("Cookie", "a=1")
        let d = HTTP1.serializeRequest(method: .post, url: URL(string: "https://e-hentai.org/api.php?x=1%202")!,
                                       headers: h, body: Data("{}".utf8))
        #expect(String(decoding: d, as: UTF8.self) ==
            "POST /api.php?x=1%202 HTTP/1.1\r\nHost: e-hentai.org\r\nUser-Agent: UA\r\nCookie: a=1\r\nContent-Length: 2\r\n\r\n{}")
        let g = HTTP1.serializeRequest(method: .get, url: URL(string: "http://example.com:8080")!, headers: ["Host": "override"], body: nil)
        #expect(String(decoding: g, as: UTF8.self) == "GET / HTTP/1.1\r\nHost: override\r\n\r\n")
        #expect(HTTP1.hostHeader(for: URL(string: "https://example.com:8443/a")!) == "example.com:8443")
        #expect(HTTP1.hostHeader(for: URL(string: "https://example.com:443/a")!) == "example.com")
        // 头注入过滤
        let inj = HTTP1.serializeRequest(method: .get, url: URL(string: "https://a.org/")!, headers: ["X": "1\r\nEvil: 2"], body: nil)
        #expect(!String(decoding: inj, as: UTF8.self).contains("\r\nEvil"))
    }

    @Test func parseHeadFields() throws {
        let raw = bytes("HTTP/1.1 302 Found\r\nLocation: https://e-hentai.org/\r\nSet-Cookie: a=1\r\nset-cookie: b=2\r\nX-Fold: a\r\n  b\r\n\r\nrest")
        let (head, consumed) = try #require(try HTTP1.parseHead(raw))
        #expect(head.status == 302)
        #expect(head.reason == "Found")
        #expect(head.version == "HTTP/1.1")
        #expect(head.headers["location"] == "https://e-hentai.org/")
        #expect(head.headers.values(for: "Set-Cookie") == ["a=1", "b=2"])
        #expect(head.headers["X-Fold"] == "a b")
        #expect(consumed == raw.count - 4)
        #expect(try HTTP1.parseHead(bytes("HTTP/1.1 200 OK\r\nA: b\r\n")) == nil)
        #expect(throws: EhTransportError.self) { try HTTP1.parseHead(self.bytes("garbage\r\n\r\n")) }
    }

    @Test(arguments: [1, 3, 7, 1000])
    func contentLength(step: Int) throws {
        let raw = bytes("HTTP/1.1 200 OK\r\nContent-Length: 11\r\nContent-Type: text/html\r\n\r\nhello world")
        let r = try run(raw, step: step)
        #expect(r.head?.status == 200)
        #expect(String(decoding: r.body, as: UTF8.self) == "hello world")
        #expect(r.ended)
        #expect(r.parser.isComplete)
        #expect(r.parser.isReusable)
        #expect(r.parser.framing == .length(11))
    }

    @Test(arguments: [1, 2, 5, 64, 4096])
    func chunked(step: Int) throws {
        let raw = bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "5\r\nhello\r\n" + "1;ext=1\r\n \r\n" + "A\r\n0123456789\r\n" + "0\r\nX-Trailer: t\r\n\r\n")
        let r = try run(raw, step: step)
        #expect(String(decoding: r.body, as: UTF8.self) == "hello 0123456789")
        #expect(r.ended)
        #expect(r.parser.isReusable)
        #expect(r.parser.framing == .chunked)
    }

    @Test func chunkedDecoderDirect() throws {
        var d = ChunkedDecoder()
        let (out, left) = try d.feed(Array("3\r\nabc\r\n0\r\n\r\nNEXT".utf8))
        #expect(String(decoding: out, as: UTF8.self) == "abc")
        #expect(d.isDone)
        #expect(String(decoding: left, as: UTF8.self) == "NEXT")
        var bad = ChunkedDecoder()
        #expect(throws: EhTransportError.self) { try bad.feed(Array("zz\r\n".utf8)) }
    }

    @Test func skipsContinueAndHandlesNoBody() throws {
        let raw = bytes("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 204 No Content\r\nX: 1\r\n\r\n")
        let r = try run(raw, step: 4)
        #expect(r.head?.status == 204)
        #expect(r.body.isEmpty)
        #expect(r.ended)

        let head = try run(bytes("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n"), step: 100, method: .head)
        #expect(head.ended)
        #expect(head.parser.framing == .none)

        let notModified = try run(bytes("HTTP/1.1 304 Not Modified\r\nContent-Length: 5\r\n\r\n"), step: 100)
        #expect(notModified.ended)
    }

    @Test func untilCloseAndKeepAliveRules() throws {
        let raw = bytes("HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\nbody until close")
        let r = try run(raw, step: 5, eof: true)
        #expect(String(decoding: r.body, as: UTF8.self) == "body until close")
        #expect(r.ended)
        #expect(!r.parser.isReusable)

        let close = try run(bytes("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"), step: 50)
        #expect(close.ended && !close.parser.isReusable)
        let ka10 = try run(bytes("HTTP/1.0 200 OK\r\nConnection: keep-alive\r\nContent-Length: 1\r\n\r\nx"), step: 50)
        #expect(ka10.parser.isReusable)
        let leftover = try run(bytes("HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nxy"), step: 50)
        #expect(String(decoding: leftover.body, as: UTF8.self) == "x")
        #expect(!leftover.parser.isReusable)
    }

    @Test func truncatedBodiesThrowOnEOF() throws {
        var p = HTTP1ResponseParser()
        _ = try p.feed(bytes: bytes("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc"))
        #expect(throws: EhTransportError.self) { try p.finish() }
        var q = HTTP1ResponseParser()
        _ = try q.feed(bytes: bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nab"))
        #expect(throws: EhTransportError.self) { try q.finish() }
        var r = HTTP1ResponseParser()
        #expect(throws: EhTransportError.self) { try r.finish() }
    }
}

@Suite struct ContentDecodingTests {
    static let html: String = "<html><head><title>E-Hentai Galleries</title></head><body>"
        + (0..<40).map { i in "<div class=\"gl1t\"><a href=\"https://e-hentai.org/g/\(1000 + i)/abcdef\(String(format: "%04d", i))/\">Gallery \(i)</a></div>" }.joined()
        + "</body></html>"
    static let gzipB64 = "H4sICAAAAAAC/2luZGV4Lmh0bWwApdfLbsIwFIThV0HsqTPncK1CdlX7GmkJBCktFUSVePteWMyw7ews2fq9+mSfuh/fh6buu3bX1ONxHLrmafbSfYztcfLcDkN3PnaXutx26nI793raXZt6d/yavA3t5bKdHgaM06ZuJ/2522+n/Th+Xh5L6Wb9X+nhdD6UQ0FVVaV9fdt1++p3OW1uN1wnVV3an/pP8X9ZMAvJwswGsyHZMLPJbEo2zeyc2blk52Z2wexCsgszu2R2KdmlmV0xu5LsysyumV1Ldm1mN8xuJLvxsqAyqDKYzEBmuGNmOgOdQZ3BhAZCg0KDKQ2UBpUGkxpIDUoNpjXQGtQaTGwgNig2mNpAbVBtMLmB3KDcYHoLegv1Fqa3oLdQb2F6C3qLu3fN9Bb0FuotTG9Bb6HewvQW9BbqLUxvQW+h3sL0FvQW6i1Mb0Fvod7C9Bb0FuotTG9Jb6ne0vSW9JbqLU1vSW+p3tL0lvSWdx9J01vSW6q3NL0lvaV6S9Nb0luqtzS9Jb2lekvTW9Jbqrc0vSW9pXpL9VZuw1v5m/u+Afd4FRb+DQAA"

    @Test func gzipWithFilenameHeader() throws {
        let data = try #require(Data(base64Encoded: Self.gzipB64))
        let out = try ContentDecoding.decode(data, contentEncoding: "gzip")
        #expect(String(decoding: out, as: UTF8.self) == Self.html)
        // 纯 Swift 路径
        let bytes = [UInt8](data)
        let start = try ContentDecoding.gzipHeaderLength(bytes, at: 0)
        #expect(start == 10 + "index.html".count + 1)
        var inf = Inflate(input: bytes, position: start)
        #expect(String(decoding: try inf.run(), as: UTF8.self) == Self.html)
    }

    @Test func rawDeflateFixedHuffman() throws {
        let raw = [UInt8](Data(base64Encoded: "y0jNyclXyEAiy/OLclIA")!)
        #expect(String(decoding: try Inflate.inflate(raw), as: UTF8.self) == "hello hello hello world")
        let viaHeader = try ContentDecoding.decode(Data(raw), contentEncoding: "deflate")
        #expect(String(decoding: viaHeader, as: UTF8.self) == "hello hello hello world")
    }

    @Test func zlibWrappedDeflate() throws {
        let z = Data(base64Encoded: "eJxLSU3LSSxJVajKyUxSKC9KLChITVEoSKzMyU/EoAF5phDY")!
        let out = try ContentDecoding.decode(z, contentEncoding: "Deflate")
        #expect(String(decoding: out, as: UTF8.self) == "deflate zlib wrapped payload payload payload")
    }

    @Test func storedBlock() throws {
        let s = [UInt8](Data(base64Encoded: "AQ0A8v9zdG9yZWQgYmxvY2sh")!)
        #expect(String(decoding: try Inflate.inflate(s), as: UTF8.self) == "stored block!")
    }

    @Test func identityAndErrors() throws {
        let d = Data("plain".utf8)
        #expect(try ContentDecoding.decode(d, contentEncoding: nil) == d)
        #expect(try ContentDecoding.decode(d, contentEncoding: "identity") == d)
        #expect(throws: EhTransportError.self) { try ContentDecoding.decode(d, contentEncoding: "br") }
        #expect(throws: EhTransportError.self) { try ContentDecoding.decode(d, contentEncoding: "gzip") }
        let truncated = Data(base64Encoded: Self.gzipB64)!.prefix(100)
        #expect(throws: (any Error).self) { try ContentDecoding.decode(Data(truncated), contentEncoding: "gzip") }
    }
}
