import TurboDraftMarkdown
import XCTest

final class MarkdownEnterBehaviorTests: XCTestCase {
  func testContinuesUnorderedListAtEndOfDocument() {
    let doc = "- item"
    let cursor = (doc as NSString).length
    let edit = MarkdownEnterBehavior.editForEnter(in: doc, selection: NSRange(location: cursor, length: 0))
    XCTAssertEqual(
      edit,
      MarkdownEnterEdit(
        replaceRange: NSRange(location: cursor, length: 0),
        replacement: "\n- ",
        selectedLocation: cursor + 3
      )
    )
  }

  func testContinuesOrderedListBeforeExistingNewline() {
    let doc = "1. first\nnext"
    let cursor = ("1. first" as NSString).length
    let edit = MarkdownEnterBehavior.editForEnter(in: doc, selection: NSRange(location: cursor, length: 0))
    XCTAssertEqual(
      edit,
      MarkdownEnterEdit(
        replaceRange: NSRange(location: cursor, length: 0),
        replacement: "\n2. ",
        selectedLocation: cursor + 4
      )
    )
  }

  func testExitsEmptyListItemByRemovingPrefix() {
    let doc = "- "
    let cursor = (doc as NSString).length
    let edit = MarkdownEnterBehavior.editForEnter(in: doc, selection: NSRange(location: cursor, length: 0))
    XCTAssertEqual(
      edit,
      MarkdownEnterEdit(
        replaceRange: NSRange(location: 0, length: 2),
        replacement: "",
        selectedLocation: 0
      )
    )
  }

  func testContinuesTaskAsUnchecked() {
    let doc = "- [x] done"
    let cursor = (doc as NSString).length
    let edit = MarkdownEnterBehavior.editForEnter(in: doc, selection: NSRange(location: cursor, length: 0))
    XCTAssertEqual(
      edit,
      MarkdownEnterEdit(
        replaceRange: NSRange(location: cursor, length: 0),
        replacement: "\n- [ ] ",
        selectedLocation: cursor + 7
      )
    )
  }

  func testContinuesPlainQuote() {
    let doc = "> a thought"
    let cursor = (doc as NSString).length
    let edit = MarkdownEnterBehavior.editForEnter(in: doc, selection: NSRange(location: cursor, length: 0))
    XCTAssertEqual(
      edit,
      MarkdownEnterEdit(
        replaceRange: NSRange(location: cursor, length: 0),
        replacement: "\n> ",
        selectedLocation: cursor + 3
      )
    )
  }

  func testSplitListItemWhenCaretInMiddle() {
    let doc = "- item"
    let cursor = 4 // - it|em
    let edit = MarkdownEnterBehavior.editForEnter(in: doc, selection: NSRange(location: cursor, length: 0))
    XCTAssertEqual(
      edit,
      MarkdownEnterEdit(
        replaceRange: NSRange(location: cursor, length: 0),
        replacement: "\n- ",
        selectedLocation: cursor + 3
      )
    )
  }

  func testCreatesNewItemAboveWhenAtStartOfLine() {
    let doc = "- first"
    let cursor = 0
    let edit = MarkdownEnterBehavior.editForEnter(in: doc, selection: NSRange(location: cursor, length: 0))
    XCTAssertEqual(
      edit,
      MarkdownEnterEdit(
        replaceRange: NSRange(location: 0, length: 0),
        replacement: "- \n",
        selectedLocation: 2
      )
    )
  }

  func testCreatesOrderedItemAboveUsingCurrentIndex() {
    let doc = "3. third"
    let cursor = 0
    let edit = MarkdownEnterBehavior.editForEnter(in: doc, selection: NSRange(location: cursor, length: 0))
    XCTAssertEqual(
      edit,
      MarkdownEnterEdit(
        replaceRange: NSRange(location: 0, length: 0),
        replacement: "3. \n",
        selectedLocation: 3
      )
    )
  }

  func testNoContinuationInsideFencedCodeBlock() {
    let doc = "```md\n- item"
    let cursor = (doc as NSString).length
    let edit = MarkdownEnterBehavior.editForEnter(in: doc, selection: NSRange(location: cursor, length: 0))
    XCTAssertNil(edit)
  }

  func testNestedUnorderedListPreservesIndentation() {
    let doc = "  - child"
    let cursor = (doc as NSString).length
    let edit = MarkdownEnterBehavior.editForEnter(in: doc, selection: NSRange(location: cursor, length: 0))
    XCTAssertEqual(
      edit,
      MarkdownEnterEdit(
        replaceRange: NSRange(location: cursor, length: 0),
        replacement: "\n  - ",
        selectedLocation: cursor + 5
      )
    )
  }

  func testNestedOrderedListPreservesIndentationAndIncrements() {
    let doc = "    7) step"
    let cursor = (doc as NSString).length
    let edit = MarkdownEnterBehavior.editForEnter(in: doc, selection: NSRange(location: cursor, length: 0))
    XCTAssertEqual(
      edit,
      MarkdownEnterEdit(
        replaceRange: NSRange(location: cursor, length: 0),
        replacement: "\n    8) ",
        selectedLocation: cursor + 8
      )
    )
  }

  func testNestedListAtPrefixBoundaryCreatesItemAbove() {
    let doc = "  - child"
    let cursor = 2 // at marker start
    let edit = MarkdownEnterBehavior.editForEnter(in: doc, selection: NSRange(location: cursor, length: 0))
    XCTAssertEqual(
      edit,
      MarkdownEnterEdit(
        replaceRange: NSRange(location: 0, length: 0),
        replacement: "  - \n",
        selectedLocation: 4
      )
    )
  }

  func testNestedTaskListContinuesAsUnchecked() {
    let doc = "    - [x] done"
    let cursor = (doc as NSString).length
    let edit = MarkdownEnterBehavior.editForEnter(in: doc, selection: NSRange(location: cursor, length: 0))
    XCTAssertEqual(
      edit,
      MarkdownEnterEdit(
        replaceRange: NSRange(location: cursor, length: 0),
        replacement: "\n    - [ ] ",
        selectedLocation: cursor + 11
      )
    )
  }
}
