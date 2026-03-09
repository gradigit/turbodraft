import Foundation
@testable import TurboDraftAgent
import XCTest

private final class FakeCodexAppServerTransport: CodexAppServerTransport {
  var isAlive: Bool = true
  var sendRequestError: Error?
  var sentNotifications: [(method: String, params: [String: Any])] = []

  private var nextRequestID = 1
  private let responses: [Int: [String: Any]]
  private var messages: [[String: Any]]

  init(
    responses: [Int: [String: Any]],
    messages: [[String: Any]] = []
  ) {
    self.responses = responses
    self.messages = messages
  }

  func shutdown() {
    isAlive = false
  }

  func ensureInitialized(timeoutMs _: Int) throws {}

  func sendRequest(method _: String, params _: [String: Any]) throws -> Int {
    if let sendRequestError {
      throw sendRequestError
    }
    defer { nextRequestID += 1 }
    return nextRequestID
  }

  func sendNotification(method: String, params: [String: Any]) throws {
    sentNotifications.append((method, params))
  }

  func waitForResponse(id: Int, timeoutMs _: Int) throws -> [String: Any] {
    if let response = responses[id] {
      return response
    }
    throw CodexAppServerPromptEngineerError.protocolError("missing fake response for id \(id)")
  }

  func readNextMessage(timeoutMs _: Int) throws -> [String: Any]? {
    guard !messages.isEmpty else { return nil }
    return messages.removeFirst()
  }
}

private final class LockedStringBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value = ""

  func append(_ chunk: String) {
    lock.lock()
    value += chunk
    lock.unlock()
  }

  func snapshot() -> String {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

final class CodexAppServerPromptEngineerAdapterTests: XCTestCase {
  private func makeAdapter(transport: FakeCodexAppServerTransport) -> CodexAppServerPromptEngineerAdapter {
    CodexAppServerPromptEngineerAdapter(
      command: "codex",
      routeLabel: "codex app-server (test)",
      serverFactory: { transport }
    )
  }

  private var validLegacyOutput: String {
    """
    ## Implementation Steps
    1. Rewrite the request into a concise execution-ready prompt.
    2. Preserve all constraints, formatting requirements, and expected output language.
    """
  }

  func testDraftReturnsOnCompletedFinalAgentMessageWithoutTurnCompleted() async throws {
    let transport = FakeCodexAppServerTransport(
      responses: [
        1: ["result": ["thread": ["id": "thread-1"]]],
        2: ["result": ["turn": ["id": "turn-1"]]],
      ],
      messages: [
        [
          "method": "item/completed",
          "params": [
            "turnId": "turn-1",
            "item": [
              "type": "agentMessage",
              "phase": "final_answer",
              "text": validLegacyOutput,
            ],
          ],
        ],
      ]
    )
    let adapter = makeAdapter(transport: transport)

    let out = try await adapter.draft(prompt: "draft", instruction: "instruction", images: [], cwd: nil)

    XCTAssertEqual(out, validLegacyOutput)
    XCTAssertEqual(adapter.lastRouteLabel, "codex app-server (test)")
  }

  func testChatStreamsCodexAgentMessageContentDelta() async throws {
    let transport = FakeCodexAppServerTransport(
      responses: [
        1: ["result": ["thread": ["id": "thread-1"]]],
        2: ["result": ["turn": ["id": "turn-1"]]],
      ],
      messages: [
        [
          "method": "codex/event/agent_message_content_delta",
          "params": [
            "msg": [
              "turn_id": "turn-1",
              "delta": "Hello",
            ],
          ],
        ],
        [
          "method": "item/completed",
          "params": [
            "turnId": "turn-1",
            "item": [
              "type": "agentMessage",
              "phase": "final_answer",
              "text": "Hello",
            ],
          ],
        ],
      ]
    )
    let adapter = makeAdapter(transport: transport)
    let collected = LockedStringBox()

    let out = try await adapter.chat(
      message: "message",
      draft: "draft",
      images: [],
      cwd: nil,
      onDelta: { collected.append($0) }
    )

    XCTAssertEqual(collected.snapshot(), "Hello")
    XCTAssertEqual(out, "Hello")
    XCTAssertEqual(adapter.lastRouteLabel, "codex app-server (test) chat")
  }

  func testDraftStillSupportsLegacyTurnCompletedPath() async throws {
    let transport = FakeCodexAppServerTransport(
      responses: [
        1: ["result": ["thread": ["id": "thread-1"]]],
        2: ["result": ["turn": ["id": "turn-1"]]],
      ],
      messages: [
        [
          "method": "item/agentMessage/delta",
          "params": [
            "turnId": "turn-1",
            "delta": "## Implementation Steps\n1. Rewrite the request into a concise execution-ready prompt.\n",
          ],
        ],
        [
          "method": "item/agentMessage/delta",
          "params": [
            "turnId": "turn-1",
            "delta": "2. Preserve all constraints, formatting requirements, and expected output language.\n",
          ],
        ],
        [
          "method": "turn/completed",
          "params": [
            "threadId": "thread-1",
            "turn": [
              "id": "turn-1",
              "status": "completed",
            ],
          ],
        ],
      ]
    )
    let adapter = makeAdapter(transport: transport)

    let out = try await adapter.draft(prompt: "draft", instruction: "instruction", images: [], cwd: nil)

    XCTAssertTrue(out.contains("## Implementation Steps"))
    XCTAssertTrue(out.contains("2. Preserve all constraints"))
  }

  func testChatSurfacesWriteFailureImmediately() async {
    let transport = FakeCodexAppServerTransport(
      responses: [:],
      messages: []
    )
    transport.sendRequestError = CodexAppServerPromptEngineerError.writeFailed(errno: EPIPE)
    let adapter = makeAdapter(transport: transport)

    do {
      _ = try await adapter.chat(message: "message", draft: "draft", images: [], cwd: nil)
      XCTFail("Expected write failure")
    } catch let error as CodexAppServerPromptEngineerError {
      if case let .writeFailed(errnoValue) = error {
        XCTAssertEqual(errnoValue, EPIPE)
      } else {
        XCTFail("Unexpected error: \(error)")
      }
    } catch {
      XCTFail("Wrong error type: \(error)")
    }
  }
}
