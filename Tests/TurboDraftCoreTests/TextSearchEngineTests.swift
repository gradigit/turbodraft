import XCTest
@testable import TurboDraftCore

final class TextSearchEngineTests: XCTestCase {
  func testMakeRegexLiteralCaseInsensitiveByDefault() {
    let re = TextSearchEngine.makeRegex(query: "Hello.", options: .init())
    XCTAssertNotNil(re)
    let summary = TextSearchEngine.summarizeMatches(
      in: "hello.\nHELLO.\nhello?",
      query: "Hello.",
      options: .init()
    )
    XCTAssertEqual(summary?.totalCount, 2)
  }

  func testMakeRegexCaseSensitive() {
    let summary = TextSearchEngine.summarizeMatches(
      in: "abc ABC Abc",
      query: "ABC",
      options: .init(caseSensitive: true)
    )
    XCTAssertEqual(summary?.totalCount, 1)
  }

  func testWholeWordHonorsBoundaries() {
    let summary = TextSearchEngine.summarizeMatches(
      in: "cat concatenate cat.",
      query: "cat",
      options: .init(wholeWord: true)
    )
    XCTAssertEqual(summary?.totalCount, 2)
  }

  func testRegexModeSupportsPattern() {
    let summary = TextSearchEngine.summarizeMatches(
      in: "a1 a2 aA",
      query: #"a\d"#,
      options: .init(regexEnabled: true)
    )
    XCTAssertEqual(summary?.totalCount, 2)
  }

  func testInvalidRegexReturnsNil() {
    let summary = TextSearchEngine.summarizeMatches(
      in: "abc",
      query: "(",
      options: .init(regexEnabled: true)
    )
    XCTAssertNil(summary)
  }

  func testCaptureLimitCapsRangesButKeepsTotalCount() {
    let summary = TextSearchEngine.summarizeMatches(
      in: "x x x x x",
      query: "x",
      options: .init(),
      captureLimit: 2
    )
    XCTAssertEqual(summary?.totalCount, 5)
    XCTAssertEqual(summary?.ranges.count, 2)
  }

  func testReplacementForRegexMatchSupportsGroups() {
    let text = "hello 123"
    let range = NSRange(location: 6, length: 3)
    let out = TextSearchEngine.replacementForMatch(
      in: text,
      range: range,
      query: #"(\d+)"#,
      replacementTemplate: "[$1]",
      options: .init(regexEnabled: true)
    )
    XCTAssertEqual(out, "[123]")
  }

  func testReplaceAllLiteral() {
    let result = TextSearchEngine.replaceAll(
      in: "foo Foo fOo",
      query: "foo",
      replacementTemplate: "bar",
      options: .init()
    )
    XCTAssertEqual(result?.count, 3)
    XCTAssertEqual(result?.text, "bar bar bar")
  }

  func testReplaceAllRegex() {
    let result = TextSearchEngine.replaceAll(
      in: "a1 a2",
      query: #"a(\d)"#,
      replacementTemplate: "b$1",
      options: .init(regexEnabled: true)
    )
    XCTAssertEqual(result?.count, 2)
    XCTAssertEqual(result?.text, "b1 b2")
  }

  func testSummarizeMatchesLargeInputWithinBudget() {
    let line = "alpha beta gamma alpha delta alpha\n"
    let doc = String(repeating: line, count: 20_000)
    let clock = ContinuousClock()
    let elapsed = clock.measure {
      let summary = TextSearchEngine.summarizeMatches(
        in: doc,
        query: "alpha",
        options: .init(),
        captureLimit: 700
      )
      XCTAssertNotNil(summary)
      XCTAssertEqual(summary?.ranges.count, 700)
      XCTAssertEqual(summary?.totalCount, 60_000)
    }
    XCTAssertLessThan(elapsed.components.seconds, 1, "summarizeMatches unexpectedly slow")
  }

  func testReplaceAllLargeInputWithinBudget() {
    let line = "alpha beta gamma alpha delta alpha\n"
    let doc = String(repeating: line, count: 20_000)
    let clock = ContinuousClock()
    let elapsed = clock.measure {
      let result = TextSearchEngine.replaceAll(
        in: doc,
        query: "alpha",
        replacementTemplate: "omega",
        options: .init()
      )
      XCTAssertNotNil(result)
      XCTAssertEqual(result?.count, 60_000)
    }
    XCTAssertLessThan(elapsed.components.seconds, 1, "replaceAll unexpectedly slow")
  }
}
