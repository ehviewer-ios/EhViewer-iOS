import Foundation

/// 评论投票 API（method=votecomment）响应。对应 Android `parser/VoteCommentParser`
/// 示例：{"comment_id":1253922,"comment_score":-19,"comment_vote":0}
public enum VoteCommentParser {
    public struct Result: Codable, Sendable, Hashable {
        public var id: Int64
        public var score: Int
        /// 投票后的状态：1 赞，-1 踩，0 已取消
        public var vote: Int
        /// 请求时期望的投票值
        public var expectVote: Int
        public init(id: Int64, score: Int, vote: Int, expectVote: Int) {
            self.id = id; self.score = score; self.vote = vote; self.expectVote = expectVote
        }
    }

    public static func parse(_ body: String, vote: Int) throws -> Result {
        guard let jo = MiscJSON.object(body),
              let id = MiscJSON.int64(jo["comment_id"]),
              let score = MiscJSON.int64(jo["comment_score"]),
              let v = MiscJSON.int64(jo["comment_vote"]) else {
            throw EhError.parseFailure("Can't parse vote comment", html: body)
        }
        return Result(id: id, score: Int(score), vote: Int(v), expectVote: vote)
    }
}
