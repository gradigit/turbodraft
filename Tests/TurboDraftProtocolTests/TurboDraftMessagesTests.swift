import TurboDraftProtocol
import XCTest

final class TurboDraftMessagesTests: XCTestCase {
  func testHelloParamsDefaultsProtocolVersion() {
    let params = HelloParams(client: "test")
    XCTAssertEqual(params.protocolVersion, TurboDraftProtocolVersion.current)
  }

  func testSessionOpenParamsDefaultsProtocolVersion() {
    let params = SessionOpenParams(path: "/tmp/x.md")
    XCTAssertEqual(params.protocolVersion, TurboDraftProtocolVersion.current)
  }

  func testSessionCloseResultRoundTrip() throws {
    let data = try JSONEncoder().encode(SessionCloseResult(ok: true))
    let decoded = try JSONDecoder().decode(SessionCloseResult.self, from: data)
    XCTAssertEqual(decoded, SessionCloseResult(ok: true))
  }
}
