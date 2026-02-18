import TurboDraftTransport
import XCTest

final class ContentLengthFramerTests: XCTestCase {
  func testParsesSingleFrameAcrossChunks() throws {
    let framer = ContentLengthFramer()
    let body = #"{"jsonrpc":"2.0","id":1,"method":"x"}"#
    let msg = "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
    let a = Data(msg.utf8.prefix(10))
    let b = Data(msg.utf8.dropFirst(10))

    XCTAssertEqual(try framer.append(a).count, 0)
    let frames = try framer.append(b)
    XCTAssertEqual(frames.count, 1)
    XCTAssertEqual(String(decoding: frames[0], as: UTF8.self), body)
  }

  func testMissingContentLengthThrows() {
    let framer = ContentLengthFramer()
    let msg = "X-Foo: 1\r\n\r\n{}"
    XCTAssertThrowsError(try framer.append(Data(msg.utf8)))
  }

  func testInvalidContentLengthThrows() {
    let framer = ContentLengthFramer()
    let msg = "Content-Length: nope\r\n\r\n{}"
    XCTAssertThrowsError(try framer.append(Data(msg.utf8)))
  }

  func testFrameTooLargeThrows() {
    let framer = ContentLengthFramer(maxFrameBytes: 1)
    let body = "{}"
    let msg = "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
    XCTAssertThrowsError(try framer.append(Data(msg.utf8)))
  }

  func testParsesMultipleFramesInOneChunk() throws {
    let framer = ContentLengthFramer()
    let body1 = #"{"id":1}"#
    let body2 = #"{"id":2}"#
    let msg1 = "Content-Length: \(body1.utf8.count)\r\n\r\n\(body1)"
    let msg2 = "Content-Length: \(body2.utf8.count)\r\n\r\n\(body2)"
    let frames = try framer.append(Data((msg1 + msg2).utf8))
    XCTAssertEqual(frames.count, 2)
    XCTAssertEqual(String(decoding: frames[0], as: UTF8.self), body1)
    XCTAssertEqual(String(decoding: frames[1], as: UTF8.self), body2)
  }
}
