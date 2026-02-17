import PromptPadProtocol
import PromptPadTransport
import XCTest

final class UnixDomainSocketTests: XCTestCase {
  func testBindDoesNotStealActiveSocket() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let sock = dir.appendingPathComponent("test.sock").path

    let server = try UnixDomainSocketServer(socketPath: sock)
    XCTAssertThrowsError(try UnixDomainSocketServer(socketPath: sock)) { err in
      guard case UnixDomainSocketError.alreadyRunning = err else {
        XCTFail("expected alreadyRunning, got \(err)")
        return
      }
    }
    server.stop()
  }

  func testServerClientHello() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let sock = dir.appendingPathComponent("test.sock").path

    let server = try UnixDomainSocketServer(socketPath: sock)
    let exp = expectation(description: "server handled")
    server.start { fd in
      let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      let conn = JSONRPCConnection(readHandle: handle, writeHandle: handle)
      let serverConn = JSONRPCServerConnection(connection: conn) { req in
        if req.method == PromptPadMethod.hello, let id = req.id {
          let res = JSONRPCResponse(id: id, result: .object(["ok": .bool(true)]), error: nil)
          exp.fulfill()
          return res
        }
        return nil
      }
      serverConn.run()
    }

    let cfd = try UnixDomainSocket.connect(path: sock)
    let ch = FileHandle(fileDescriptor: cfd, closeOnDealloc: true)
    let client = JSONRPCConnection(readHandle: ch, writeHandle: ch)
    let req = JSONRPCRequest(id: .int(1), method: PromptPadMethod.hello, params: .object(["client": .string("t")]))
    try client.sendJSON(req)
    let resp = try client.readResponse()
    XCTAssertNotNil(resp.result)
    try? ch.close()
    wait(for: [exp], timeout: 2.0)
    server.stop()
  }
}
