import Foundation

/// `api.php` gtoken 接口解析，返回第一个条目的 token。对应 Android `client/parser/GalleryTokenApiParser`
///
///     { "tokenlist": [ { "gid": 618395, "token": "0439fa3666" } ] }
public enum GalleryTokenApiParser {
    public static func parse(_ body: String) throws -> String {
        guard let jo = GalleryJSON.object(body),
              let list = jo["tokenlist"] as? [Any],
              let first = list.first as? [String: Any] else {
            throw EhError.parseFailure("Can't parse tokenlist", html: body)
        }
        if let token = GalleryJSON.string(first, "token") {
            return token
        }
        guard let error = GalleryJSON.string(first, "error") else {
            throw EhError.parseFailure("Can't parse token", html: body)
        }
        throw EhError.server(error)
    }
}
