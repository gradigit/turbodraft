import TurboDraftAgent
import XCTest

final class SpawnEnvironmentTests: XCTestCase {
  func testMergedReplacesExistingAndAddsNewKeys() {
    let base = [
      "PATH=/usr/bin:/bin",
      "OPENAI_BASE_URL=https://api.openai.com/v1",
      "FOO=old",
    ]
    let merged = SpawnEnvironment.merged(base: base, overrides: [
      "OPENAI_BASE_URL": "http://127.0.0.1:4000",
      "FOO": "new",
      "BAR": "added",
    ])

    XCTAssertTrue(merged.contains("OPENAI_BASE_URL=http://127.0.0.1:4000"))
    XCTAssertTrue(merged.contains("FOO=new"))
    XCTAssertTrue(merged.contains("BAR=added"))
    XCTAssertFalse(merged.contains("FOO=old"))
  }

  func testMergedKeepsBaseWhenNoOverrides() {
    let base = [
      "A=1",
      "B=2",
    ]
    XCTAssertEqual(SpawnEnvironment.merged(base: base, overrides: [:]), base)
  }
}
