import PromptPadAgent
import XCTest

final class PromptEngineerPromptsTests: XCTestCase {
  func testComposeUsesDefaultInstructionWhenEmpty() {
    let out = PromptEngineerPrompts.compose(prompt: "p", instruction: "")
    XCTAssertTrue(out.contains("TASK:"))
    XCTAssertTrue(out.contains(PromptEngineerPrompts.defaultInstruction.trimmingCharacters(in: .whitespacesAndNewlines)))
    XCTAssertTrue(out.contains("<BEGIN_PROMPT>\np\n<END_PROMPT>"))
  }

  func testUserTurnTextDoesNotIncludeSystemPreamble() {
    let out = PromptEngineerPrompts.userTurnText(prompt: "p", instruction: "")
    XCTAssertTrue(out.contains("TASK:"))
    XCTAssertFalse(out.contains("You are PromptPad, a prompt engineering assistant."))
  }

  func testComposeWithCoreProfileUsesCorePreamble() {
    let out = PromptEngineerPrompts.compose(prompt: "p", instruction: "", profile: .core)
    XCTAssertTrue(out.contains("You are PromptPad, a prompt engineering assistant."))
  }

  func testPreambleForProfileIsStableAcrossCalls() {
    let p1 = PromptEngineerPrompts.preamble(for: .largeOpt)
    let p2 = PromptEngineerPrompts.preamble(for: .largeOpt)
    XCTAssertFalse(p1.isEmpty)
    XCTAssertEqual(p1, p2)
  }
}
