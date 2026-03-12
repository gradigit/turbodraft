import Foundation
import TurboDraftCore
import TurboDraftProtocol
import TurboDraftTransport
import XCTest

private final class ServerTaskBox: @unchecked Sendable {
  private let lock = NSLock()
  private var task: Task<Void, Never>?

  func set(_ task: Task<Void, Never>) {
    lock.lock()
    self.task = task
    lock.unlock()
  }

  func get() -> Task<Void, Never>? {
    lock.lock()
    defer { lock.unlock() }
    return task
  }
}

final class CLIFLowTests: XCTestCase {
  func testOpenSaveFlowOverUnixDomainSocket() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let fileURL = dir.appendingPathComponent("prompt.md")
    let initial = "hello"
    try initial.data(using: .utf8)?.write(to: fileURL, options: [.atomic])

    let sock = dir.appendingPathComponent("server.sock").path
    let session = EditorSession()
    let serverTaskBox = ServerTaskBox()
    let serverTaskStarted = expectation(description: "server task started")

    let server = try UnixDomainSocketServer(socketPath: sock)
    server.start { fd in
      let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      let conn = JSONRPCConnection(readHandle: handle, writeHandle: handle)
      let serverConn = JSONRPCServerConnection(connection: conn) { req in
        guard let id = req.id else { return nil }

        func ok(_ obj: [String: JSONValue]) -> JSONRPCResponse {
          JSONRPCResponse(id: id, result: .object(obj), error: nil)
        }

        func err(_ code: Int, _ message: String) -> JSONRPCResponse {
          JSONRPCResponse(id: id, result: nil, error: JSONRPCErrorObject(code: code, message: message))
        }

        do {
          switch req.method {
          case TurboDraftMethod.hello:
            return ok(["ok": .bool(true)])

          case TurboDraftMethod.sessionOpen:
            let params = try (req.params ?? .object([:])).decode(SessionOpenParams.self)
            let path = params.path
            let info = try await session.open(fileURL: URL(fileURLWithPath: path))
            return ok([
              "sessionId": .string(info.sessionId),
              "path": .string(info.fileURL.path),
              "content": .string(info.content),
              "revision": .string(info.diskRevision),
              "isDirty": .bool(info.isDirty),
            ])

          case TurboDraftMethod.sessionSave:
            let params = try (req.params ?? .object([:])).decode(SessionSaveParams.self)
            let content = params.content
            await session.updateBufferContent(content)
            let _ = try await session.autosave(reason: "rpc_save")
            let info = await session.currentInfo()
            return ok([
              "ok": .bool(true),
              "revision": .string(info?.diskRevision ?? ""),
            ])

          default:
            return err(JSONRPCStandardErrorCode.methodNotFound, "Unknown method")
          }
        } catch {
          return err(JSONRPCStandardErrorCode.internalError, "handler failed: \(error)")
        }
      }
      serverTaskBox.set(serverConn.run())
      serverTaskStarted.fulfill()
    }

    let cfd = try UnixDomainSocket.connect(path: sock)
    let ch = FileHandle(fileDescriptor: cfd, closeOnDealloc: true)
    let client = JSONRPCConnection(readHandle: ch, writeHandle: ch)

    try client.sendJSON(JSONRPCRequest(id: .int(1), method: TurboDraftMethod.hello, params: .null))
    _ = try client.readResponse()

    try client.sendJSON(JSONRPCRequest(id: .int(2), method: TurboDraftMethod.sessionOpen, params: .object([
      "path": .string(fileURL.path),
    ])))
    let openResp = try client.readResponse()
    let openRes = try (openResp.result ?? .null).decode(SessionOpenResult.self)
    XCTAssertEqual(openRes.content, initial)

    let newContent = "updated\nline2"
    try client.sendJSON(JSONRPCRequest(id: .int(3), method: TurboDraftMethod.sessionSave, params: .object([
      "sessionId": .string(openRes.sessionId),
      "content": .string(newContent),
    ])))
    let saveResp = try client.readResponse()
    let saveRes = try (saveResp.result ?? .null).decode(SessionSaveResult.self)
    XCTAssertTrue(saveRes.ok)

    let disk = try String(contentsOf: fileURL, encoding: .utf8)
    XCTAssertEqual(disk, newContent)

    try? ch.close()
    wait(for: [serverTaskStarted], timeout: 2.0)
    server.stop()
    let task = serverTaskBox.get()
    let drained = expectation(description: "server task drained")
    Task {
      _ = await task?.result
      drained.fulfill()
    }
    wait(for: [drained], timeout: 2.0)
  }
}
