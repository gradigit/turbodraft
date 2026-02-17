import PromptPadAgent
import XCTest

final class PromptEngineerOutputGuardTests: XCTestCase {
  func testFlagsPromptRewriterBoilerplateAndDraftEcho() {
    let draft = String(repeating: "abc ", count: 100) + "tail"
    let out = """
    You are PromptPad, a prompt engineering assistant.

    ## Output Requirements
    Return only the rewritten prompt text.

    Draft Prompt to Rewrite
    <BEGIN_PROMPT>
    \(draft)
    <END_PROMPT>
    """

    let res = PromptEngineerOutputGuard.check(draft: draft, output: out)
    XCTAssertTrue(res.needsRepair)
    XCTAssertTrue(res.reasons.contains("leaked_system_preamble"))
    XCTAssertTrue(res.reasons.contains("looks_like_prompt_rewriter"))
    XCTAssertTrue(res.reasons.contains("contains_prompt_markers"))
    XCTAssertTrue(res.reasons.contains("contains_draft_prefix"))
  }

  func testFlagsInputsNeededHeadingAndTodoPastePlaceholders() {
    let draft = "Square corners in flush mode; check prior logs."
    let out = """
    ## Context
    - Some context

    ## Inputs Needed
    - [TODO: paste a screenshot of the UI]
    - [TODO: paste the relevant logs]

    ## Task
    Make corners square in flush mode.
    """

    let res = PromptEngineerOutputGuard.check(draft: draft, output: out)
    XCTAssertTrue(res.needsRepair)
    XCTAssertTrue(res.reasons.contains("uses_inputs_needed_heading"))
    XCTAssertTrue(res.reasons.contains("contains_todo_paste_placeholders"))
  }

  func testAllowsNormalStructuredRewrite() {
    let draft = "Make the window corners square in flush mode."
    let out = """
    # Feature: Flush Mode Window Chrome

    ## Goal
    Update flush mode window styling to use square corners and improve separation.

    ## Constraints
    - macOS AppKit

    ## Implementation Steps
    1. Find flush mode styling.
    2. Apply square corners in flush mode only.

    ## Acceptance Criteria
    - Corners are square when flush mode is enabled.
    """

    let res = PromptEngineerOutputGuard.check(draft: draft, output: out)
    XCTAssertFalse(res.needsRepair)
    XCTAssertEqual(res.reasons, [])
  }

  func testNormalizesActionableTaskHeadingToImplementationSteps() {
    let out = """
    ## Actionable Task
    1. Do thing one.
    2. Do thing two.
    """
    let normalized = PromptEngineerOutputGuard.normalize(output: out)
    XCTAssertTrue(normalized.contains("## Implementation Steps"))
    XCTAssertFalse(normalized.contains("## Actionable Task"))
  }

  func testFlagsMissingActionableNumberedStepSection() {
    let draft = "Make the window corners square in flush mode."
    let out = """
    # Feature
    ## Goal
    Make flush mode corners square.
    """

    let res = PromptEngineerOutputGuard.check(draft: draft, output: out)
    XCTAssertTrue(res.needsRepair)
    XCTAssertTrue(res.reasons.contains("missing_actionable_numbered_step_section"))
  }

  func testSuggestedRepairEffortBumps() {
    XCTAssertEqual(PromptEngineerOutputGuard.suggestedRepairEffort("low"), "medium")
    XCTAssertEqual(PromptEngineerOutputGuard.suggestedRepairEffort("medium"), "high")
    XCTAssertEqual(PromptEngineerOutputGuard.suggestedRepairEffort("high"), "xhigh")
    XCTAssertEqual(PromptEngineerOutputGuard.suggestedRepairEffort("xhigh"), "xhigh")
    XCTAssertEqual(PromptEngineerOutputGuard.suggestedRepairEffort("none"), "low")
    XCTAssertEqual(PromptEngineerOutputGuard.suggestedRepairEffort(""), "")
  }
}
