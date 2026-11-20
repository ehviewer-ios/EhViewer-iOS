import Foundation
@testable import EhNetwork

/// 读取 EhCoreTests 的 HTML 样本（不同 test target，用 #filePath 相对定位）
enum APIFixture {
    static func text(_ name: String, ext: String = "html") throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EhCoreTests/Fixtures/\(name).\(ext)")
        return try String(contentsOf: url, encoding: .utf8)
    }
}

/// 按顺序记录请求，按 handler 返回响应
func makeAPI(_ env: EhAPIEnvironment = EhAPIEnvironment(), hooks: EhAPIHooks = EhAPIHooks(),
             _ handler: @escaping @Sendable (EhHTTPRequest) throws -> EhHTTPResponse) -> (EhAPI, MockTransport) {
    let mock = MockTransport(handler)
    let client = EhHTTPClient(transport: mock)
    return (EhAPI(client: client, environment: env, hooks: hooks), mock)
}

func html(_ r: EhHTTPRequest, _ body: String, status: Int = 200) -> EhHTTPResponse {
    resp(status, r.url, body: body)
}

func json(_ r: EhHTTPRequest, _ body: String, status: Int = 200) -> EhHTTPResponse {
    resp(status, r.url, headers: ["Content-Type": "application/json"], body: body)
}

extension EhHTTPRequest {
    var bodyString: String { String(decoding: body ?? Data(), as: UTF8.self) }
    var urlString: String { url.absoluteString }
}

/// 线程安全的计数 / 收集器
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&_value) } }
}

/// 构造 gmetadata 响应
func gmetadata(_ items: [(gid: Int64, token: String, tags: [String], pages: Int)]) -> String {
    let parts = items.map { i in
        let tags = i.tags.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"gid":\(i.gid),"token":"\(i.token)","title":"T\(i.gid)","title_jpn":"","category":"Manga","thumb":"https://ehgt.org/w/01/234/x.jpg","uploader":"u","posted":"1700000000","filecount":"\(i.pages)","rating":"4.5","tags":[\(tags)]}
        """
    }
    return "{\"gmetadata\":[\(parts.joined(separator: ","))]}"
}
