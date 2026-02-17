import PromptPadMarkdown
import XCTest

final class MarkdownListContinuationTests: XCTestCase {
  func testUnorderedListContinues() {
    XCTAssertEqual(
      MarkdownListContinuation.actionForEnter(in: "- item"),
      .continueWith(prefix: "- ")
    )
    XCTAssertEqual(
      MarkdownListContinuation.actionForEnter(in: "  * item"),
      .continueWith(prefix: "  * ")
    )
    XCTAssertEqual(
      MarkdownListContinuation.actionForEnter(in: "\t+ item"),
      .continueWith(prefix: "\t+ ")
    )
  }

  func testUnorderedListEmptyExits() {
    XCTAssertEqual(
      MarkdownListContinuation.actionForEnter(in: "- "),
      .exit(removingPrefix: "- ")
    )
    XCTAssertEqual(
      MarkdownListContinuation.actionForEnter(in: "  *   "),
      .exit(removingPrefix: "  *   ")
    )
  }

  func testTaskListContinuesAsUnchecked() {
    XCTAssertEqual(
      MarkdownListContinuation.actionForEnter(in: "- [x] done"),
      .continueWith(prefix: "- [ ] ")
    )
    XCTAssertEqual(
      MarkdownListContinuation.actionForEnter(in: "- [X] done"),
      .continueWith(prefix: "- [ ] ")
    )
    XCTAssertEqual(
      MarkdownListContinuation.actionForEnter(in: "  - [ ] todo"),
      .continueWith(prefix: "  - [ ] ")
    )
  }

  func testTaskListEmptyExits() {
    XCTAssertEqual(
      MarkdownListContinuation.actionForEnter(in: "- [ ] "),
      .exit(removingPrefix: "- [ ] ")
    )
    XCTAssertEqual(
      MarkdownListContinuation.actionForEnter(in: "- [x]    "),
      .exit(removingPrefix: "- [x]    ")
    )
  }

  func testOrderedListContinuesAndIncrements() {
    XCTAssertEqual(
      MarkdownListContinuation.actionForEnter(in: "1. first"),
      .continueWith(prefix: "2. ")
    )
    XCTAssertEqual(
      MarkdownListContinuation.actionForEnter(in: "9) step"),
      .continueWith(prefix: "10) ")
    )
    XCTAssertEqual(
      MarkdownListContinuation.actionForEnter(in: "  42. answer"),
      .continueWith(prefix: "  43. ")
    )
  }

  func testOrderedListEmptyExits() {
    XCTAssertEqual(
      MarkdownListContinuation.actionForEnter(in: "3. "),
      .exit(removingPrefix: "3. ")
    )
    XCTAssertEqual(
      MarkdownListContinuation.actionForEnter(in: "10)   "),
      .exit(removingPrefix: "10)   ")
    )
  }

  func testQuotePrefixedLists() {
    XCTAssertEqual(
      MarkdownListContinuation.actionForEnter(in: "> - item"),
      .continueWith(prefix: "> - ")
    )
    XCTAssertEqual(
      MarkdownListContinuation.actionForEnter(in: "> 1. item"),
      .continueWith(prefix: "> 2. ")
    )
    XCTAssertEqual(
      MarkdownListContinuation.actionForEnter(in: "> - "),
      .exit(removingPrefix: "> - ")
    )
  }

  func testPlainQuoteContinuationAndExit() {
    XCTAssertEqual(
      MarkdownListContinuation.actionForEnter(in: "> discussing tradeoffs"),
      .continueWith(prefix: "> ")
    )
    XCTAssertEqual(
      MarkdownListContinuation.actionForEnter(in: ">> nested quote"),
      .continueWith(prefix: ">> ")
    )
    XCTAssertEqual(
      MarkdownListContinuation.actionForEnter(in: "> "),
      .exit(removingPrefix: "> ")
    )
  }

  func testNonListDoesNothing() {
    XCTAssertNil(MarkdownListContinuation.actionForEnter(in: "plain paragraph"))
    XCTAssertNil(MarkdownListContinuation.actionForEnter(in: "-item"))
    XCTAssertNil(MarkdownListContinuation.actionForEnter(in: "[ ] not a list"))
  }
}
