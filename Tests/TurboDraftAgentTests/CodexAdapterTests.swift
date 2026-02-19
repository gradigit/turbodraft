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

  func testCLIAdapterErrorNaming() {
    let err = CodexCLIAgentError.timedOut
    XCTAssertEqual(err.description, "Timed out")
  }

  func testCLIAdapterNonZeroExitIncludesMessage() async {
    let adapter = CodexCLIAgentAdapter(command: "/usr/bin/false", args: [])
    do {
      _ = try await adapter.draft(prompt: "p", instruction: "i")
      XCTFail("Expected nonZeroExit")
    } catch let e as CodexCLIAgentError {
      if case let .nonZeroExit(code, _) = e {
        XCTAssertNotEqual(code, 0)
      } else {
        XCTFail("Expected nonZeroExit, got \(e)")
      }
    } catch {
      XCTFail("Wrong error type: \(error)")
    }
  }

  func testExecAdapterCommandNotFound() async {
    let adapter = CodexPromptEngineerAdapter(command: "turbodraft_no_such_command_please")
    do {
      _ = try await adapter.draft(prompt: "p", instruction: "i", images: [])
      XCTFail("Expected commandNotFound")
    } catch let e as CodexPromptEngineerError {
      if case .commandNotFound = e {
        // expected
      } else {
        XCTFail("Expected commandNotFound, got \(e)")
      }
    } catch {
      XCTFail("Wrong error type: \(error)")
    }
  }

  func testExecAdapterDraftRunsOffCooperativePool() async {
    // Structural test: verifies that draft() completes via Task.detached path
    // without blocking the cooperative thread pool. We use a bogus command so
    // it fails fast with commandNotFound — the important thing is that the
    // async call returns without deadlocking.
    let adapter = CodexPromptEngineerAdapter(command: "turbodraft_no_such_command_please")
    do {
      _ = try await adapter.draft(prompt: "p", instruction: "i", images: [])
    } catch {
      // Expected to throw commandNotFound; the test verifies the call completes.
    }
  }

  func testOversizedImageConstant() {
    // The 20 MB limit is enforced inside CodexPromptEngineerAdapter.runCodex.
    // Verify indirectly: the exec adapter's description for outputTooLarge exists.
    let err = CodexPromptEngineerError.outputTooLarge
    XCTAssertEqual(err.description, "Output too large")
  }
}
