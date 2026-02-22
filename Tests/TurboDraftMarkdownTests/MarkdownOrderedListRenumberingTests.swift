import TurboDraftMarkdown
import XCTest

final class MarkdownOrderedListRenumberingTests: XCTestCase {
  func testRenumbersContiguousOrderedBlock() {
    let doc = """
    1. one
    4. two
    9. three
    """
    let out = MarkdownOrderedListRenumbering.renumber(document: doc, around: 8)
    XCTAssertEqual(
      out,
      """
      1. one
      2. two
      3. three
      """
    )
  }

  func testRenumberKeepsPrefixAndDelimiter() {
    let doc = """
    > 7) quoted
    > 9) also quoted
    > 10) final
    """
    let out = MarkdownOrderedListRenumbering.renumber(document: doc, around: 5)
    XCTAssertEqual(
      out,
      """
      > 7) quoted
      > 8) also quoted
      > 9) final
      """
    )
  }

  func testNoChangeWhenNotOrderedList() {
    let doc = "- bullet\n- bullet"
    XCTAssertNil(MarkdownOrderedListRenumbering.renumber(document: doc, around: 1))
  }
}
