import Foundation
import XCTest
@testable import iosApp

final class DailyNativeContractTests: XCTestCase {
    func testDailyOriginParserFindsOriginLinkAndRoutesAnswer() throws {
        let html = #"<a class="originUrl" href="https://www.zhihu.com/question/7/answer/42">查看原文</a>"#
        let url = try XCTUnwrap(DailyHTMLOriginParser.originURL(in: html))

        XCTAssertEqual(
            DailyRouteResolver.destination(url: url, fallbackTitle: "问题"),
            .feed(.answer(answerID: 42, questionID: 7, questionTitle: "问题"))
        )
    }

    func testDailyUnrecognizedOriginRemainsRealExternalDestination() throws {
        let url = URL(string: "https://zhuanlan.zhihu.com/special/weekly")!
        XCTAssertEqual(DailyRouteResolver.destination(url: url, fallbackTitle: "日报"), .external(url))
    }
}

final class PinNativeContractTests: XCTestCase {
    func testPinMapperPreservesBlocksPollRelationshipAndCounts() throws {
        let data = Data(
            #"{"id":"12","url":"https://www.zhihu.com/pin/12","author":{"id":"member","url_token":"writer","name":"作者","avatar_url":"https://pic.zhimg.com/a.jpg","headline":"简介"},"content":[{"type":"text","content":"<p>正文 <a href=\"https://www.zhihu.com/question/7\">问题</a></p>"},{"type":"image","url":"https://pic.zhimg.com/p.jpg"}],"created":10,"updated":20,"like_count":4,"comment_count":5,"virtuals":{"is_liked":true},"topics":[{"name":"iOS"}],"bottom_poll":{"voting":{"id":"8","title":"选择","member_count":2,"is_voted":false,"end_at":-1,"options":[{"id":"1","title":"A","voting_count":2}]}}}"#.utf8
        )

        let detail = try PinResponseMapper.detail(from: data, expectedID: 12)

        XCTAssertEqual(detail.author.displayName, "作者")
        XCTAssertEqual(detail.blocks.count, 2)
        XCTAssertTrue(detail.isLiked)
        XCTAssertEqual(detail.likeCount, 4)
        XCTAssertEqual(detail.commentCount, 5)
        XCTAssertEqual(detail.topics, ["iOS"])
        XCTAssertTrue(detail.poll?.acceptsVote == true)
    }

    func testPinHTMLParserKeepsFirstSeenLinkOrderWithoutDuplicates() {
        let first = "https://www.zhihu.com/question/1"
        let second = "https://www.zhihu.com/question/2"
        let result = PinHTMLParser.parse(
            #"<a href="https://www.zhihu.com/question/1">一</a><a href="https://www.zhihu.com/question/2">二</a><a href="https://www.zhihu.com/question/1">一</a>"#
        )
        XCTAssertEqual(result.links.map(\.absoluteString), [first, second])
    }
}
