import XCTest

@testable import PhotoTagger

final class TagParserTests: XCTestCase {

    func testPlainCommaList() {
        let raw = "woman in yellow, yellow shirt, lake, mountains, sunny day"
        XCTAssertEqual(
            TagParser.parse(raw),
            ["woman in yellow", "yellow shirt", "lake", "mountains", "sunny day"])
    }

    func testThinkingBlockIsStripped() {
        let raw = """
            <think>The person is wearing yellow by a lake. I will list tags.</think>
            woman, yellow shirt, lake
            """
        XCTAssertEqual(TagParser.parse(raw), ["woman", "yellow shirt", "lake"])
    }

    func testUnterminatedThinkingYieldsNothing() {
        XCTAssertEqual(TagParser.parse("<think>yellow shirt, lake"), [])
    }

    func testNumberedListWithPrefix() {
        let raw = """
            Tags:
            1. woman in yellow shirt
            2. lake
            3. - summer day
            """
        XCTAssertEqual(
            TagParser.parse(raw), ["woman in yellow shirt", "lake", "summer day"])
    }

    func testBulletedList() {
        let raw = """
            * woman wearing yellow
            * lake
            * hiking
            """
        XCTAssertEqual(TagParser.parse(raw), ["woman wearing yellow", "lake", "hiking"])
    }

    func testMarkdownCodeFence() {
        let raw = """
            ```
            dog, golden retriever, park, fetch
            ```
            """
        XCTAssertEqual(
            TagParser.parse(raw), ["dog", "golden retriever", "park", "fetch"])
    }

    func testJSONArray() {
        let raw = #"["birthday party", "cake", "candles", "indoor"]"#
        XCTAssertEqual(
            TagParser.parse(raw), ["birthday party", "cake", "candles", "indoor"])
    }

    func testSemicolonsAndNewlines() {
        let raw = """
            sunset; beach
            silhouette
            """
        XCTAssertEqual(TagParser.parse(raw), ["sunset", "beach", "silhouette"])
    }

    func testDeduplicationCaseInsensitive() {
        XCTAssertEqual(
            TagParser.parse("Lake, lake, LAKE, mountains"),
            ["lake", "mountains"])
    }

    func testFillersAndJunkAreDropped() {
        XCTAssertEqual(TagParser.parse("photo, image, n/a, unclear"), [])
    }

    func testLeadingArticleStripped() {
        XCTAssertEqual(TagParser.parse("a woman, an outdoor scene"), ["woman", "outdoor scene"])
    }

    func testLongTagsRejected() {
        XCTAssertFalse(TagParser.parse("a very long tag with far too many words").contains("very long tag with far too many words"))
        XCTAssertEqual(TagParser.parse("this tag has way too many words inside it, lake"), ["lake"])
    }

    func testMaxTagsCapped() {
        let raw = (1...20).map { "tag number \($0)" }.joined(separator: ", ")
        XCTAssertEqual(TagParser.parse(raw).count, 12)
    }

    func testTagsWithPunctuationRejected() {
        XCTAssertEqual(TagParser.parse("lake #sunset, smile:)"), [])
    }

    func testQuotesTrimmed() {
        XCTAssertEqual(
            TagParser.parse(#""yellow shirt", "lake""#), ["yellow shirt", "lake"])
    }

    func testEmptyAndWhitespace() {
        XCTAssertEqual(TagParser.parse(""), [])
        XCTAssertEqual(TagParser.parse("   \n\t , ,"), [])
    }

    func testBlackAndWhiteStyleTag() {
        XCTAssertEqual(
            TagParser.parse("black and white, portrait, studio"),
            ["black and white", "portrait", "studio"])
    }
}
