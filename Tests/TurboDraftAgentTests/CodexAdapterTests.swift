import TurboDraftAgent
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
    let adapter = CodexCLIAgentAdapter(command: "turbodraft_no_such_command_please", args: [])
    do {
      _ = try await adapter.draft(prompt: "p", instruction: "i")
      XCTFail("Expected commandNotFound")
    } catch {
      // ok
    }
  }

  func testAdapterIgnoresImagesGracefully() async throws {
    // CodexCLIAgentAdapter logs a warning when images are passed but still
    // produces output from the underlying command.
    let adapter = CodexCLIAgentAdapter(command: "/bin/cat", args: [])
    let fakeImage = URL(fileURLWithPath: "/dev/null")
    let out = try await adapter.draft(prompt: "p", instruction: "i", images: [fakeImage])
    XCTAssertTrue(out.contains("PROMPT:"))
    XCTAssertTrue(out.contains("INSTRUCTION:"))
  }
}
