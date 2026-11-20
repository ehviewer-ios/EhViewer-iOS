import Testing
@testable import EhCore

/// RateGalleryParser / VoteCommentParser / GetEditCommentParser
@Suite struct ApiResultParserTests {
    @Test func rateGallery() throws {
        let r = try RateGalleryParser.parse(#"{"rating_avg":4.53,"rating_usr":4.5,"rating_cnt":123,"rating_cls":"ir irb"}"#)
        #expect(abs(r.rating - 4.53) < 0.0001)
        #expect(r.ratingCount == 123)
        #expect(throws: EhError.self) { try RateGalleryParser.parse(#"{"error":"x"}"#) }
        #expect(throws: EhError.self) { try RateGalleryParser.parse("not json") }
    }

    @Test func voteComment() throws {
        let r = try VoteCommentParser.parse(#"{"comment_id":1253922,"comment_score":-19,"comment_vote":0}"#, vote: 1)
        #expect(r.id == 1_253_922)
        #expect(r.score == -19)
        #expect(r.vote == 0)
        #expect(r.expectVote == 1)
        #expect(throws: EhError.self) { try VoteCommentParser.parse("{}", vote: 1) }
    }

    @Test func getEditComment() throws {
        let json = #"{"comment_id":42,"editable_comment":"<form><textarea name=\"commenttext_edit\">line1\nline2 &amp; <b></textarea></form>"}"#
        let r = try GetEditCommentParser.parse(json)
        #expect(r.id == 42)
        #expect(r.comment == "line1\nline2 & <b>")
        #expect(throws: EhError.server("No permission")) {
            try GetEditCommentParser.parse(#"{"error":"No permission"}"#)
        }
        #expect(throws: EhError.self) {
            try GetEditCommentParser.parse(#"{"comment_id":1,"editable_comment":"<p>none</p>"}"#)
        }
    }
}
