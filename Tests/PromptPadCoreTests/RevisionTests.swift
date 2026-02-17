import PromptPadCore
import XCTest

final class RevisionTests: XCTestCase {
  func testSha256Stable() {
    let a = Revision.sha256(text: "hello")
    let b = Revision.sha256(text: "hello")
    XCTAssertEqual(a, b)
    XCTAssertNotEqual(a, Revision.sha256(text: "hello2"))
    XCTAssertTrue(a.hasPrefix("sha256:"))
  }
}

