import TurboDraftAgent
import XCTest

final class PromptEngineerPromptsTests: XCTestCase {
  func testComposeUsesDefaultInstructionWhenEmpty() {
    let out = PromptEngineerPrompts.compose(prompt: "p", instruction: "")
    XCTAssertTrue(out.contains("TASK:"))
    XCTAssertTrue(out.contains(PromptEngineerPrompts.defaultInstruction.trimmingCharacters(in: .whitespacesAndNewlines)))
    XCTAssertTrue(out.contains("<BEGIN_PROMPT>\np\n<END_PROMPT>"))
    XCTAssertFalse(out.contains("PRESET CONTRACT:"))
  }

  func testUserTurnTextDoesNotIncludeSystemPreamble() {
    let out = PromptEngineerPrompts.userTurnText(prompt: "p", instruction: "")
    XCTAssertTrue(out.contains("TASK:"))
    XCTAssertFalse(out.contains("You are TurboDraft, a prompt engineering assistant."))
  }

  func testComposeWithCoreProfileUsesCorePreamble() {
    let out = PromptEngineerPrompts.compose(prompt: "p", instruction: "", profile: .core)
    XCTAssertTrue(out.contains("You are TurboDraft, a prompt engineering assistant."))
  }

  func testComposeIncludesPresetContract() {
    let out = PromptEngineerPrompts.compose(prompt: "p", instruction: "", preset: .brainstorm)
    XCTAssertTrue(out.contains("PRESET:\nbrainstorm"))
    XCTAssertTrue(out.contains("exploration-oriented"))
  }

  func testLegacyPresetOmitsPresetContractBlock() {
    let out = PromptEngineerPrompts.compose(prompt: "p", instruction: "", preset: .legacy)
    XCTAssertFalse(out.contains("PRESET CONTRACT:"))
    XCTAssertTrue(out.contains("AI coding agent"))
  }

  func testLegacyUserTurnKeepsBaseInstructionWhenAdditionalConstraintsProvided() {
    let out = PromptEngineerPrompts.userTurnText(
      prompt: "p",
      instruction: "- extra constraint",
      preset: .legacy
    )
    XCTAssertTrue(out.contains("AI coding agent"))
    XCTAssertTrue(out.contains("Additional constraints:"))
    XCTAssertTrue(out.contains("- extra constraint"))
  }

  func testPivotReasonPresetIncludesLanguagePolicyContract() {
    let out = PromptEngineerPrompts.compose(prompt: "한국어 초안", instruction: "", preset: .pivotKrEnReasonKo)
    XCTAssertTrue(out.contains("PRESET:\npivot_kr_en_reason_ko"))
    XCTAssertTrue(out.contains("analyze/reason in English internally"))
    XCTAssertTrue(out.contains("respond to the user in Korean"))
    XCTAssertTrue(out.lowercased().contains("do not mention drafting_agent or execution_agent"))
  }

  func testPivotOptimizePresetRequiresStructuredSections() {
    let instruction = PromptEngineerPrompts.defaultInstruction(for: .pivotKrEnOptimizeKo)
    XCTAssertTrue(instruction.contains("Objective"))
    XCTAssertTrue(instruction.contains("Context and Constraints"))
    XCTAssertTrue(instruction.contains("Language Policy"))
    XCTAssertTrue(instruction.contains("internal analysis/reasoning in English"))
    XCTAssertTrue(instruction.contains("final answer in Korean"))
  }

  func testCodingPresetRequiresTaskPlanningAndNoInternalRoleNames() {
    let instruction = PromptEngineerPrompts.defaultInstruction(for: .coding)
    XCTAssertTrue(instruction.contains("create and maintain a task checklist"))
    XCTAssertTrue(instruction.contains("do not mention drafting_agent or execution_agent"))
  }

  func testBrainstormPresetRequiresThreeOptionsIncludingContrarian() {
    let instruction = PromptEngineerPrompts.defaultInstruction(for: .brainstorm)
    XCTAssertTrue(instruction.contains("at least 3 distinct options"))
    XCTAssertTrue(instruction.contains("contrarian option"))
    XCTAssertTrue(instruction.contains("Option Space / Tradeoffs"))
  }

  func testPreambleForProfileIsStableAcrossCalls() {
    let p1 = PromptEngineerPrompts.preamble(for: .largeOpt)
    let p2 = PromptEngineerPrompts.preamble(for: .largeOpt)
    XCTAssertFalse(p1.isEmpty)
    XCTAssertEqual(p1, p2)
  }

  // MARK: - effectiveReasoningEffort

  func testEffortPassthroughForNonSpark() {
    let result = PromptEngineerPrompts.effectiveReasoningEffort(model: "gpt-5.3", requested: "high")
    XCTAssertEqual(result, "high")
  }

  func testSparkMinimalBecomesLow() {
    let result = PromptEngineerPrompts.effectiveReasoningEffort(model: "gpt-5.3-codex-spark", requested: "minimal")
    XCTAssertEqual(result, "low")
  }

  func testCodexMinimalBecomesNone() {
    let result = PromptEngineerPrompts.effectiveReasoningEffort(model: "gpt-5.3-codex", requested: "minimal")
    XCTAssertEqual(result, "none")
  }

  func testEmptyEffortReturnsEmpty() {
    let result = PromptEngineerPrompts.effectiveReasoningEffort(model: "gpt-5.3-codex-spark", requested: "")
    XCTAssertEqual(result, "")
  }

  func testEffortWithWhitespace() {
    let result = PromptEngineerPrompts.effectiveReasoningEffort(model: "gpt-5.3", requested: "  high  ")
    XCTAssertEqual(result, "high")
  }
}
