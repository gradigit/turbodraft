import PromptPadProtocol
import XCTest

final class JSONValueTests: XCTestCase {
  func testEncodeDecodeRoundTrip() throws {
    let v: JSONValue = .object([
      "a": .int(1),
      "b": .string("x"),
      "c": .array([.bool(true), .null]),
    ])
    let data = try JSONEncoder().encode(v)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    XCTAssertEqual(decoded, v)
  }
}

