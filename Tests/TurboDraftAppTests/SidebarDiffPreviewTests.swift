import XCTest
@testable import TurboDraftApp

@MainActor
final class SidebarDiffPreviewTests: XCTestCase {
  func testExtractSuggestedDraftFromMarkdownFence() {
    let reply = """
    Suggested rewrite:
    ```markdown
    # Title
    - item
    ```
    """
    XCTAssertEqual(EditorViewController.extractSuggestedDraft(from: reply), "# Title\n- item")
  }

  func testExtractDiffCodeBlock() {
    let reply = """
    ```diff
    --- current
    +++ suggested
    @@
    -old
    +new
    ```
    """
    let extracted = EditorViewController.extractDiffCodeBlock(from: reply)
    XCTAssertNotNil(extracted)
    XCTAssertTrue(extracted?.contains("+++ suggested") == true)
  }

  func testUnifiedLineDiffIncludesAddAndRemoveLines() {
    let diff = EditorViewController.unifiedLineDiff(from: "a\nb", to: "a\nc")
    XCTAssertTrue(diff.contains("--- current"))
    XCTAssertTrue(diff.contains("+++ suggested"))
    XCTAssertTrue(diff.contains("-b"))
    XCTAssertTrue(diff.contains("+c"))
  }
}
