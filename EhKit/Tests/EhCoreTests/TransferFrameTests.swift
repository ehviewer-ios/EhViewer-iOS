import Foundation
import Testing
@testable import EhCore

// 期望字节按 Android WiFiFrameCodec.java（DataOutputStream，大端）手工构造

private func be32(_ v: Int32) -> [UInt8] {
    let x = UInt32(bitPattern: v)
    return [UInt8(x >> 24), UInt8((x >> 16) & 0xFF), UInt8((x >> 8) & 0xFF), UInt8(x & 0xFF)]
}

private func be64(_ v: Int64) -> [UInt8] {
    let x = UInt64(bitPattern: v)
    return (0..<8).map { UInt8((x >> UInt64(56 - $0 * 8)) & 0xFF) }
}

private func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

/// writeString：u16 长度 + UTF-8
private func jstr(_ s: String) -> [UInt8] { be16(s.utf8.count) + Array(s.utf8) }

private func header(_ mt: UInt8, _ dt: Int, _ pi: Int32, _ ps: Int32, _ flags: Int, _ len: Int) -> [UInt8] {
    [0x45, 0x48, 0x42, 0x46, 0x01, mt] + be16(dt) + be32(pi) + be32(ps) + be16(flags) + be32(Int32(len))
}

@Suite struct TransferFrameTests {
    @Test func headerBytesMatchJava() throws {
        let f = WiFiFrame(messageType: 2, dataType: 1001, pageIndex: 1, pageSize: 3, flags: 0, payload: Data("ab".utf8))
        let bytes = [UInt8](WiFiFrameCodec.encode(f))
        #expect(bytes == [0x45, 0x48, 0x42, 0x46, 0x01, 0x02, 0x03, 0xE9,
                          0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x03,
                          0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x61, 0x62])
        #expect(WiFiFrameCodec.headerSize == 22)
        #expect(try WiFiFrameCodec.decode(Data(bytes)) == f)
    }

    @Test func headerTruncatesLikeJavaWriteByteAndShort() throws {
        // writeByte / writeShort 只写低位；读回为无符号
        let f = WiFiFrame(messageType: 0x1FF, dataType: 0x1_2345, pageIndex: -1, pageSize: Int32.min, flags: 0x1_0001)
        let bytes = [UInt8](WiFiFrameCodec.encode(f))
        #expect(bytes == [0x45, 0x48, 0x42, 0x46, 0x01, 0xFF, 0x23, 0x45,
                          0xFF, 0xFF, 0xFF, 0xFF, 0x80, 0x00, 0x00, 0x00,
                          0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
        let back = try WiFiFrameCodec.decode(Data(bytes))
        #expect(back.messageType == 0xFF)
        #expect(back.dataType == 0x2345)
        #expect(back.pageIndex == -1)
        #expect(back.pageSize == Int32.min)
        #expect(back.flags == 1)
        #expect(back.payload.isEmpty)
    }

    @Test func manifestBytesMatchJava() throws {
        let files = [
            WiFiDownloadMigration.FileMeta(name: "00000001.jpg", md5: "d41d8cd98f00b204e9800998ecf8427e", size: 5),
            WiFiDownloadMigration.FileMeta(name: "子/中.png", md5: "ab", size: 0x1_0000_0000),
        ]
        let frame = try WiFiFrameCodec.encodeManifest(gid: 0x0102_0304_0506_0708, dirname: "123-标题",
                                                      files: files, pageIndex: 1, pageSize: 2)
        var payload = be64(0x0102_0304_0506_0708) + jstr("123-标题") + be16(2)
        payload += jstr("00000001.jpg") + jstr("d41d8cd98f00b204e9800998ecf8427e") + be64(5)
        payload += jstr("子/中.png") + jstr("ab") + be64(0x1_0000_0000)
        let expected = header(2, 1005, 1, 2, 0, payload.count) + payload
        #expect([UInt8](WiFiFrameCodec.encode(frame)) == expected)

        let decoded = try #require(WiFiFrameCodec.decodeManifest(try WiFiFrameCodec.decode(Data(expected))))
        #expect(decoded.gid == 0x0102_0304_0506_0708)
        #expect(decoded.dirname == "123-标题")
        #expect(decoded.files == files)
        #expect(decoded.pageIndex == 1)
        #expect(decoded.pageSize == 2)
    }

    @Test func ackBytesMatchJava() throws {
        let frame = try WiFiFrameCodec.encodeAck(gid: 42, dirname: "42-x", filesNeeded: ["a", "b/c"])
        let payload = be64(42) + jstr("42-x") + be16(2) + jstr("a") + jstr("b/c")
        let expected = header(1, 1006, 0, 0, 0, payload.count) + payload
        #expect([UInt8](WiFiFrameCodec.encode(frame)) == expected)
        let ack = try #require(WiFiFrameCodec.decodeAck(frame))
        #expect(ack == .init(gid: 42, dirname: "42-x", filesNeeded: ["a", "b/c"]))

        let empty = try WiFiFrameCodec.encodeAck(gid: 1, dirname: "1-", filesNeeded: [])
        #expect(WiFiFrameCodec.decodeAck(empty)?.filesNeeded == [])
    }

    @Test func fileChunkBytesMatchJava() throws {
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let frame = try WiFiFrameCodec.encodeFileChunk(gid: -2, name: "1.jpg", fileMd5: "m", chunkIndex: 3,
                                                       chunkTotal: 4, data: data, lastChunk: true)
        let payload = be64(-2) + jstr("1.jpg") + jstr("m") + be32(3) + be32(4) + be32(4) + [0xDE, 0xAD, 0xBE, 0xEF]
        let expected = header(2, 1007, 3, 4, 1, payload.count) + payload
        #expect([UInt8](WiFiFrameCodec.encode(frame)) == expected)
        let chunk = try #require(WiFiFrameCodec.decodeFileChunk(frame))
        #expect(chunk.gid == -2)
        #expect(chunk.name == "1.jpg")
        #expect(chunk.fileMd5 == "m")
        #expect(chunk.chunkIndex == 3 && chunk.chunkTotal == 4)
        #expect(chunk.data == data)
        #expect(chunk.lastChunk)

        let notLast = try WiFiFrameCodec.encodeFileChunk(gid: 1, name: "a", fileMd5: "", chunkIndex: 0,
                                                         chunkTotal: 2, data: Data(), lastChunk: false)
        #expect(notLast.flags == 0)
        #expect(WiFiFrameCodec.decodeFileChunk(notLast)?.lastChunk == false)
    }

    @Test func malformedPayloadsDecodeToNil() throws {
        let bad = WiFiFrame(messageType: 2, dataType: 1005, payload: Data([0, 1, 2]))
        #expect(WiFiFrameCodec.decodeManifest(bad) == nil)
        #expect(WiFiFrameCodec.decodeAck(bad) == nil)
        #expect(WiFiFrameCodec.decodeFileChunk(bad) == nil)
        // 负数长度
        let neg = Data(be64(1) + jstr("a") + jstr("b") + be32(0) + be32(1) + be32(-1))
        #expect(WiFiFrameCodec.decodeFileChunk(WiFiFrame(messageType: 2, dataType: 1007, payload: neg)) == nil)
        // 长度超出
        let over = Data(be64(1) + jstr("a") + jstr("b") + be32(0) + be32(1) + be32(10) + [1, 2])
        #expect(WiFiFrameCodec.decodeFileChunk(WiFiFrame(messageType: 2, dataType: 1007, payload: over)) == nil)
    }

    @Test func stringLongerThan65535Throws() throws {
        let long = String(repeating: "a", count: 65536)
        #expect(throws: WiFiFrameError.stringTooLong) {
            try WiFiFrameCodec.encodeAck(gid: 1, dirname: long, filesNeeded: [])
        }
    }

    @Test func invalidUTF8IsReplacedLikeJava() throws {
        let payload = Data(be64(1) + be16(2) + [0xC3, 0x28] + be16(0))
        let ack = try #require(WiFiFrameCodec.decodeAck(WiFiFrame(messageType: 1, dataType: 1006, payload: payload)))
        #expect(ack.dirname == "\u{FFFD}(")
    }

    // MARK: - JSON 数据帧

    @Test func dataHandRoundTrip() throws {
        var hand = WiFiDataHand(messageType: WiFiDataHand.send, dataType: TransferDataType.quickSearch,
                                pageIndex: 2, pageSize: 3)
        hand.addData("quick_search", .array([.object(["name": .string("n\"\\\n"), "mode": .int(1)])]))
        let frame = WiFiFrameCodec.encode(hand)
        #expect(frame.messageType == 2)
        #expect(frame.dataType == 1001)
        #expect(frame.pageIndex == 2 && frame.pageSize == 3)
        #expect(frame.flags == 0)
        let json = String(decoding: frame.payload, as: UTF8.self)
        #expect(json == #"{"data":{"quick_search":[{"mode":1,"name":"n\"\\\n"}]},"dataType":1001,"messageType":2,"part":2,"totalSize":3}"#)
        let back = WiFiFrameCodec.decodeDataHand(frame)
        #expect(back == hand)
    }

    @Test func decodeDataHandJsonOverridesHeader() throws {
        // fastjson 输出的键顺序不定；JSON 字段覆盖帧头
        let json = #"{"part":2,"data":{"download_label":["a",null,"b"]},"totalSize":7,"dataType":1003,"messageType":2}"#
        let frame = WiFiFrame(messageType: 2, dataType: 9, pageIndex: 5, pageSize: 6, payload: Data(json.utf8))
        let hand = WiFiFrameCodec.decodeDataHand(frame)
        #expect(hand.messageType == 2)
        #expect(hand.dataType == 1003)
        #expect(hand.pageIndex == 2)
        #expect(hand.pageSize == 7)
        #expect(hand.data?["download_label"]?.arrayValue?.compactMap(\.stringValue) == ["a", "b"])

        // 缺少字段时用帧头
        let minimal = WiFiFrame(messageType: 1, dataType: 1004, pageIndex: 3, pageSize: 4, payload: Data("{}".utf8))
        let h2 = WiFiFrameCodec.decodeDataHand(minimal)
        #expect(h2.messageType == 1 && h2.dataType == 1004 && h2.pageIndex == 3 && h2.pageSize == 4)
        #expect(h2.data == nil)

        #expect(WiFiFrameCodec.decodeDataHand(WiFiFrame(messageType: 2, dataType: 1)).messageType == WiFiDataHand.error)
        #expect(WiFiFrameCodec.decodeDataHand(WiFiFrame(messageType: 2, dataType: 1, payload: Data("{x".utf8)))
            .messageType == WiFiDataHand.error)
    }

    @Test func processedReplyEchoesData() throws {
        var hand = WiFiDataHand(messageType: WiFiDataHand.send, dataType: 1004, pageIndex: 1, pageSize: 2)
        hand.addData("favorite_info", .array([]))
        let r = hand.processedReply()
        #expect(r.messageType == WiFiDataHand.received)
        #expect(r.dataType == 1004 && r.pageIndex == 1 && r.pageSize == 2)
        #expect(r.data == hand.data)
    }

    @Test func dataHandFromJsonString() throws {
        let h = WiFiDataHand(json: #"{"messageType":2,"dataType":1001,"totalSize":3,"part":1,"data":{}}"#)
        #expect(h.messageType == 2 && h.dataType == 1001 && h.pageSize == 3 && h.pageIndex == 1)
        let bad = WiFiDataHand(json: "nope")
        #expect(bad.messageType == WiFiDataHand.error)
        #expect(bad.errorMessage != nil)
    }

    @Test func jsonValueConversions() throws {
        let v = try TransferJSON.parse(Data(#"{"a":"12","b":4.9,"c":true,"d":null,"e":-3,"f":"x","g":1e3}"#.utf8))
        #expect(v["a"]?.intValue == 12)
        #expect(v["b"]?.intValue == 4)
        #expect(v["b"]?.floatValue == 4.9)
        #expect(v["c"]?.boolValue == true)
        #expect(v["c"]?.intValue == 1)
        #expect(v["d"]?.stringValue == nil)
        #expect(v["d"]?.intValue == 0)
        #expect(v["e"]?.int64Value == -3)
        #expect(v["e"]?.stringValue == "-3")
        #expect(v["f"]?.intValue == 0)
        #expect(v["g"]?.intValue == 1000)
        #expect(TransferJSON.float(4.3).jsonString() == "4.3")
        #expect(TransferJSON.string("\u{01}中").jsonString() == "\"\\u0001中\"")
        #expect(TransferJSON.array([.null, .bool(false)]).jsonString() == "[null,false]")
    }

    // MARK: - 增量解析

    @Test func parserHandlesSplitAndCoalescedFrames() throws {
        let frames = [
            WiFiFrame(messageType: 2, dataType: 1001, pageIndex: 1, pageSize: 2, payload: Data("{\"a\":1}".utf8)),
            WiFiFrame(messageType: 1, dataType: 1006),
            WiFiFrame(messageType: 2, dataType: 1007, pageIndex: 0, pageSize: 1, flags: 1,
                      payload: Data((0..<1000).map { UInt8($0 & 0xFF) })),
        ]
        let stream = frames.reduce(Data()) { $0 + WiFiFrameCodec.encode($1) }

        // 逐字节
        var p1 = WiFiFrameParser()
        var out1: [WiFiFrame] = []
        for b in stream { out1 += try p1.append(Data([b])) }
        #expect(out1 == frames)
        #expect(p1.bufferedByteCount == 0)

        // 一次性（粘包）
        var p2 = WiFiFrameParser()
        #expect(try p2.append(stream) == frames)

        // 不规则切分
        var p3 = WiFiFrameParser()
        var out3: [WiFiFrame] = []
        var i = 0
        var step = 1
        while i < stream.count {
            let end = min(i + step, stream.count)
            out3 += try p3.append(stream.subdata(in: i..<end))
            i = end
            step = step * 3 % 37 + 1
        }
        #expect(out3 == frames)

        // 帧头完整但 payload 不完整时不输出
        var p4 = WiFiFrameParser()
        let first = WiFiFrameCodec.encode(frames[0])
        #expect(try p4.append(first.prefix(25)).isEmpty)
        #expect(try p4.append(first.dropFirst(25)) == [frames[0]])
    }

    @Test func parserRejectsBadInput() throws {
        var p = WiFiFrameParser()
        var bad = [UInt8](WiFiFrameCodec.encode(WiFiFrame(messageType: 2, dataType: 1)))
        bad[0] = 0x00
        #expect(throws: WiFiFrameError.invalidMagic) { try p.append(Data(bad)) }

        var p2 = WiFiFrameParser()
        var v2 = [UInt8](WiFiFrameCodec.encode(WiFiFrame(messageType: 2, dataType: 1)))
        v2[4] = 2
        #expect(throws: WiFiFrameError.unsupportedVersion(2)) { try p2.append(Data(v2)) }

        var p3 = WiFiFrameParser()
        let neg = header(2, 1, 0, 0, 0, 0).dropLast(4) + be32(-5)
        #expect(throws: WiFiFrameError.invalidPayloadLength(-5)) { try p3.append(Data(neg)) }

        var p4 = WiFiFrameParser(maxPayloadLength: 10)
        #expect(throws: WiFiFrameError.payloadTooLarge(11)) { try p4.append(Data(header(2, 1, 0, 0, 0, 11))) }

        #expect(throws: WiFiFrameError.truncated) { try WiFiFrameCodec.decode(Data([0x45, 0x48])) }
    }

    // MARK: - MD5

    @Test func md5Vectors() throws {
        #expect(MD5.hexString(Data()) == "d41d8cd98f00b204e9800998ecf8427e")
        #expect(MD5.hexString(Data("abc".utf8)) == "900150983cd24fb0d6963f7d28e17f72")
        #expect(MD5.hexString(Data("The quick brown fox jumps over the lazy dog".utf8))
            == "9e107d9d372bb6826bd81d3542a419d6")
        let long = Data("12345678901234567890123456789012345678901234567890123456789012345678901234567890".utf8)
        #expect(MD5.hexString(long) == "57edf4a22be3c955ac49da2e2107b67a")
        // 分段 update 与一次性一致
        let big = Data((0..<10_000).map { UInt8(($0 * 7) & 0xFF) })
        var m = MD5()
        var i = 0
        while i < big.count {
            let n = min(i + 13 + i % 70, big.count)
            m.update(big.subdata(in: i..<n))
            i = n
        }
        #expect(m.finalizeHex() == MD5.hexString(big))
    }
}
