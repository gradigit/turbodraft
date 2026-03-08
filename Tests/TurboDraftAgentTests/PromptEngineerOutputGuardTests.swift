import TurboDraftAgent
import XCTest

final class PromptEngineerOutputGuardTests: XCTestCase {
  func testFlagsPromptRewriterBoilerplateAndDraftEcho() {
    let draft = String(repeating: "abc ", count: 100) + "tail"
    let out = """
    You are TurboDraft, a prompt engineering assistant.

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

    ## Goal / Objective
    Update flush mode window styling to use square corners and improve separation.

    ## Scope and Constraints
    - macOS AppKit

    ## Implementation Steps
    1. Find flush mode styling.
    2. Apply square corners in flush mode only.

    ## Validation / Acceptance Checks
    - Corners are square when flush mode is enabled.
    - Create and maintain a task checklist while implementing.
    """

    let res = PromptEngineerOutputGuard.check(draft: draft, output: out, preset: .coding)
    XCTAssertFalse(res.needsRepair)
    XCTAssertEqual(res.reasons, [])
  }

  func testLegacyPresetRequiresNumberedImplementationStepsOnly() {
    let draft = "Tighten the prompt while preserving intent."
    let outMissingSteps = """
    ## Goal
    Improve clarity.
    """
    let missing = PromptEngineerOutputGuard.check(draft: draft, output: outMissingSteps, preset: .legacy)
    XCTAssertTrue(missing.needsRepair)
    XCTAssertTrue(missing.reasons.contains("missing_actionable_numbered_step_section"))
    XCTAssertFalse(missing.reasons.contains("missing_task_planning_instruction"))

    let outValid = """
    ## Implementation Steps
    1. Preserve all requirements.
    2. Tighten wording and structure.
    """
    let ok = PromptEngineerOutputGuard.check(draft: draft, output: outValid, preset: .legacy)
    XCTAssertFalse(ok.needsRepair)
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

    let res = PromptEngineerOutputGuard.check(draft: draft, output: out, preset: .coding)
    XCTAssertTrue(res.needsRepair)
    XCTAssertTrue(res.reasons.contains("missing_execution_structure"))
    XCTAssertTrue(res.reasons.contains("missing_task_planning_instruction"))
  }

  func testAllowsExplorationPresetStructure() {
    let draft = "Help me brainstorm options for reducing onboarding friction."
    let out = """
    ## Goal / Framing
    Explore ways to reduce onboarding friction.

    ## Open Questions
    - Which onboarding step causes largest dropoff?

    ## Option Space / Tradeoffs
    - Option A: Fewer upfront fields
    - Option B: Progressive disclosure

    ## Recommended Next Steps
    1. Compare 2 onboarding variants.
    2. Measure activation and completion rates.

    ## Evaluation Criteria
    - Activation conversion
    - Time-to-first-success
    """

    let res = PromptEngineerOutputGuard.check(draft: draft, output: out, preset: .brainstorm)
    XCTAssertFalse(res.needsRepair)
  }

  func testPivotReasonPresetRequiresLanguageContract() {
    let draft = "이 프롬프트를 영어로 바꿔줘."
    let out = """
    You are given a Korean user request. Rewrite it into English.
    """
    let res = PromptEngineerOutputGuard.check(draft: draft, output: out, preset: .pivotKrEnReasonKo)
    XCTAssertTrue(res.needsRepair)
    XCTAssertTrue(res.reasons.contains("missing_pivot_language_contract"))
  }

  func testPivotReasonPresetAcceptsEnglishReasoningAndKoreanOutputContract() {
    let draft = "한국어로 최종 답변을 받고 싶다."
    let out = """
    Translate the user request into clear English instructions.
    Analyze in English for reasoning quality.
    Final response in Korean.
    """
    let res = PromptEngineerOutputGuard.check(draft: draft, output: out, preset: .pivotKrEnReasonKo)
    XCTAssertFalse(res.needsRepair)
  }

  func testPivotPresetRejectsInternalAgentRoleNames() {
    let draft = "한국어 초안"
    let out = """
    execution_agent should answer in Korean.
    reason in English internally.
    """
    let res = PromptEngineerOutputGuard.check(draft: draft, output: out, preset: .pivotKrEnReasonKo)
    XCTAssertTrue(res.needsRepair)
    XCTAssertTrue(res.reasons.contains("contains_internal_agent_role_names"))
  }

  func testFlagsDraftEchoForShortDraftWhenMostlyVerbatim() {
    let draft = "This is a short but substantial draft that should not be echoed verbatim."
    let out = """
    ## Implementation Steps
    1. \(draft)
    2. Keep it concise.
    """
    let res = PromptEngineerOutputGuard.check(draft: draft, output: out, preset: .legacy)
    XCTAssertTrue(res.needsRepair)
    XCTAssertTrue(res.reasons.contains("contains_draft_prefix"))
  }

  func testExecutionPresetRejectsInternalAgentRoleNames() {
    let draft = "Refactor this module with tests."
    let out = """
    ## Goal / Objective
    Refactor safely.

    ## Scope and Constraints
    - Keep behavior.

    ## Implementation Steps
    1. execution_agent should create tasks.
    2. Refactor internals only.

    ## Validation / Acceptance Checks
    - Tests pass.
    """
    let res = PromptEngineerOutputGuard.check(draft: draft, output: out, preset: .refactor)
    XCTAssertTrue(res.needsRepair)
    XCTAssertTrue(res.reasons.contains("contains_internal_agent_role_names"))
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
