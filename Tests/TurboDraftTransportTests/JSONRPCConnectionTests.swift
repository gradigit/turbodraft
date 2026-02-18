import Foundation
import TurboDraftProtocol
import TurboDraftTransport
import XCTest

final class JSONRPCConnectionTests: XCTestCase {
  func testReadRequestPreservesMultipleFramesInOneChunk() throws {
    let pipe = Pipe()
    let conn = JSONRPCConnection(readHandle: pipe.fileHandleForReading, writeHandle: pipe.fileHandleForWriting)

    let encoder = JSONEncoder()
    let req1 = JSONRPCRequest(id: .int(1), method: "a", params: .null)
    let req2 = JSONRPCRequest(id: .int(2), method: "b", params: .null)
    let data1 = try encoder.encode(req1)
    let data2 = try encoder.encode(req2)

    func frame(_ body: Data) -> Data {
      var out = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
      out.append(body)
      return out
    }

    var combined = frame(data1)
    combined.append(frame(data2))
    try pipe.fileHandleForWriting.write(contentsOf: combined)
    pipe.fileHandleForWriting.closeFile()

    let a = try conn.readRequest()
    let b = try conn.readRequest()
    XCTAssertEqual(a.method, "a")
    XCTAssertEqual(b.method, "b")
  }
}

