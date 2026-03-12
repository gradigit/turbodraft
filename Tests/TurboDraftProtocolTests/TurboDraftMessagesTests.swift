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
    XCTAssertNil(params.source)
    XCTAssertNil(params.queuePath)
    XCTAssertNil(params.queueKey)
    XCTAssertNil(params.queueFormatVersion)
    XCTAssertNil(params.contextPath)
    XCTAssertNil(params.contextFormatVersion)
  }

  func testSessionOpenParamsRoundTripWithQueueAndContextAttachmentFields() throws {
    let params = SessionOpenParams(
      path: "/tmp/x.md",
      line: 3,
      column: 7,
      requestId: "req-1",
      cwd: "/tmp",
      source: "claude-pager",
      queuePath: "/Users/test/.claude/queues/abc.queue",
      queueKey: "abc",
      queueFormatVersion: 1,
      contextPath: "/Users/test/.claude/context/abc.json",
      contextFormatVersion: 1
    )
    let data = try JSONEncoder().encode(params)
    let decoded = try JSONDecoder().decode(SessionOpenParams.self, from: data)
    XCTAssertEqual(decoded, params)
  }

  func testSessionCloseResultRoundTrip() throws {
    let data = try JSONEncoder().encode(SessionCloseResult(ok: true))
    let decoded = try JSONDecoder().decode(SessionCloseResult.self, from: data)
    XCTAssertEqual(decoded, SessionCloseResult(ok: true))
  }
}
