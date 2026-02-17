import PromptPadAgent
import XCTest

final class CodexAdapterTests: XCTestCase {
  func testAdapterRunsProcess() async throws {
    // Use /bin/cat as a deterministic stand-in for codex.
    let adapter = CodexCLIAgentAdapter(command: "/bin/cat", args: [])
    let out = try await adapter.draft(prompt: "p", instruction: "i")
    XCTAssertTrue(out.contains("PROMPT:"))
    XCTAssertTrue(out.contains("INSTRUCTION:"))
  }

  func testAdapterResolvesCommandInPATH() async throws {
    let adapter = CodexCLIAgentAdapter(command: "cat", args: [])
    let out = try await adapter.draft(prompt: "p", instruction: "i")
    XCTAssertTrue(out.contains("PROMPT:"))
    XCTAssertTrue(out.contains("INSTRUCTION:"))
  }

  func testAdapterThrowsWhenCommandNotFound() async {
    let adapter = CodexCLIAgentAdapter(command: "promptpad_no_such_command_please", args: [])
    do {
      _ = try await adapter.draft(prompt: "p", instruction: "i")
      XCTFail("Expected commandNotFound")
    } catch {
      // ok
    }
  }
}
