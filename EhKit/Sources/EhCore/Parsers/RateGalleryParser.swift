import Foundation

/// 评分 API（method=rategallery）响应。对应 Android `parser/RateGalleryParser`
public enum RateGalleryParser {
    public struct Result: Codable, Sendable, Hashable {
        public var rating: Float
        public var ratingCount: Int
        public init(rating: Float, ratingCount: Int) {
            self.rating = rating
            self.ratingCount = ratingCount
        }
    }

    public static func parse(_ body: String) throws -> Result {
        guard let jo = MiscJSON.object(body),
              let avg = MiscJSON.double(jo["rating_avg"]),
              let cnt = MiscJSON.int64(jo["rating_cnt"]) else {
            throw EhError.parseFailure("Can't parse rate gallery", html: body)
        }
        return Result(rating: Float(avg), ratingCount: Int(cnt))
    }
}
