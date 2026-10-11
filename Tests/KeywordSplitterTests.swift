import XCTest

@testable import PhotoTagger

final class KeywordSplitterTests: XCTestCase {

    func testOneAndTwoWordKeywordsPassThrough() {
        XCTAssertEqual(KeywordSplitter.split("lake"), ["lake"])
        XCTAssertEqual(KeywordSplitter.split("yellow shirt"), ["yellow shirt"])
    }

    func testSplitsAtLinkingWords() {
        XCTAssertEqual(
            KeywordSplitter.split("woman in yellow shirt"),
            ["woman", "yellow shirt"])
    }

    func testMultipleLinkingWords() {
        XCTAssertEqual(
            KeywordSplitter.split("man and boy on wooden bench"),
            ["man", "boy", "wooden bench"])
    }

    func testHeadNounPhraseStaysTogether() {
        // Last two words are the noun phrase; leading modifiers stand alone.
        XCTAssertEqual(
            KeywordSplitter.split("candlelit dinner table"),
            ["candlelit", "dinner table"])
    }

    func testBlackAndWhiteSplits() {
        XCTAssertEqual(KeywordSplitter.split("black and white"), ["black", "white"])
    }

    func testDeduplicatesPieces() {
        XCTAssertEqual(
            KeywordSplitter.split("at the beach at the beach"),
            ["beach"])
    }

    func testWhitespaceAndCaseNormalized() {
        XCTAssertEqual(
            KeywordSplitter.split("  Woman  IN yellow shirt "),
            ["woman", "yellow shirt"])
    }

    func testAllLinkingWordsFallsBackToChunking() {
        // Degenerate input still yields 1-2 word pieces, never empty.
        let pieces = KeywordSplitter.split("and the of")
        XCTAssertFalse(pieces.isEmpty)
        XCTAssertTrue(
            pieces.allSatisfy { $0.components(separatedBy: " ").count <= 2 })
    }

    func testLongRunChunksFromTheRight() {
        XCTAssertEqual(
            KeywordSplitter.split("scenic mountain lake view"),
            ["scenic", "mountain", "lake view"])
    }
}
