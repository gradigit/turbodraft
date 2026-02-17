import PromptPadMarkdown
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

  func testNoContinuationWhenNotAtLineEnd() {
    let doc = "- item"
    let cursor = 2
    let edit = MarkdownEnterBehavior.editForEnter(in: doc, selection: NSRange(location: cursor, length: 0))
    XCTAssertNil(edit)
  }

  func testNoContinuationInsideFencedCodeBlock() {
    let doc = "```md\n- item"
    let cursor = (doc as NSString).length
    let edit = MarkdownEnterBehavior.editForEnter(in: doc, selection: NSRange(location: cursor, length: 0))
    XCTAssertNil(edit)
  }
}
