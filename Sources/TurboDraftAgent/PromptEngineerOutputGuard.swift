import Foundation

public enum PromptEngineerOutputGuard {
  public struct Result: Equatable {
    public var needsRepair: Bool
    public var reasons: [String]

    public init(needsRepair: Bool, reasons: [String]) {
      self.needsRepair = needsRepair
      self.reasons = reasons
    }
  }

  public static func normalize(output: String) -> String {
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let normalized = lines.map { normalizeHeadingAliases(in: $0) }
    return normalized.joined(separator: "\n")
  }

  public static func check(draft: String, output: String) -> Result {
    check(draft: draft, output: output, preset: .legacy)
  }

  public static func check(draft: String, output: String, preset: PromptEngineerPrompts.DraftingPreset) -> Result {
    let out = normalize(output: output).trimmingCharacters(in: .whitespacesAndNewlines)
    let lc = out.lowercased()
    let lines = out.split(whereSeparator: \.isNewline).map { String($0) }

    var reasons: [String] = []
    if out.isEmpty {
      reasons.append("empty_output")
    }

    if out.contains("<BEGIN_PROMPT>") || out.contains("<END_PROMPT>") {
      reasons.append("contains_prompt_markers")
    }

    if lc.contains("you are turbodraft, a prompt engineering assistant") {
      reasons.append("leaked_system_preamble")
    }

    if lc.contains("draft prompt to rewrite")
      || lc.contains("rewriting rules")
      || lc.contains("output requirements")
      || lc.contains("draft_prompt:")
      || lc.contains("draft prompt (markdown):")
      || lc.contains("draft prompt to improve:")
    {
      reasons.append("looks_like_prompt_rewriter")
    }

    if containsDraftPrefix(draft: draft, output: out) {
      reasons.append("contains_draft_prefix")
    }

    if usesInputsNeededHeading(lines: lines) {
      reasons.append("uses_inputs_needed_heading")
    }

    if containsTodoPastePlaceholders(lc: lc) {
      reasons.append("contains_todo_paste_placeholders")
    }

    switch preset {
    case .legacy:
      if !hasActionableNumberedImplementationStepsSection(lines: lines) {
        reasons.append("missing_actionable_numbered_step_section")
      }

    case .pivotKrEnTranslate:
      break

    case .pivotKrEnReasonKo:
      if !hasPivotLanguageContract(lc: lc) {
        reasons.append("missing_pivot_language_contract")
      }

    case .pivotKrEnOptimizeKo:
      if !hasExecutionStructure(lines: lines) {
        reasons.append("missing_execution_structure")
      }
      if !hasPivotLanguageContract(lc: lc) {
        reasons.append("missing_pivot_language_contract")
      }

    default:
      if preset.isExecutionOriented {
        if !hasExecutionStructure(lines: lines) {
          reasons.append("missing_execution_structure")
        }
        if !hasTaskPlanningInstruction(lc: lc) {
          reasons.append("missing_task_planning_instruction")
        }
      } else if !hasExplorationStructure(lines: lines) {
        reasons.append("missing_exploration_structure")
      }
    }

    if preset != .legacy, containsInternalAgentRoleNames(lc: lc) {
      reasons.append("contains_internal_agent_role_names")
    }

    return Result(needsRepair: !reasons.isEmpty, reasons: reasons)
  }

  public static func suggestedRepairEffort(_ effectiveEffort: String) -> String {
    let e = effectiveEffort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch e {
    case "": return ""
    case "none", "minimal": return "low"
    case "low": return "medium"
    case "medium": return "high"
    case "high": return "xhigh"
    default: return e
    }
  }

  private static func containsInternalAgentRoleNames(lc: String) -> Bool {
    lc.contains("drafting_agent") || lc.contains("execution_agent")
  }

  private static func hasPivotLanguageContract(lc: String) -> Bool {
    let hasKoreanOutput = lc.contains("respond in korean")
      || lc.contains("answer in korean")
      || lc.contains("output in korean")
      || lc.contains("final response in korean")
      || lc.contains("final answer in korean")
    let hasEnglishReasoning = lc.contains("reason in english")
      || lc.contains("analyze in english")
      || lc.contains("analysis in english")
      || lc.contains("think in english")
      || lc.contains("internally in english")
    return hasKoreanOutput && hasEnglishReasoning
  }

  private static func containsDraftPrefix(draft: String, output: String) -> Bool {
    let d = collapseWhitespace(draft)
    let o = collapseWhitespace(output)
    guard !d.isEmpty else { return false }

    // Avoid false positives on tiny drafts, but catch full echoes for most practical drafts.
    if d.count >= 60, o.contains(d) {
      return true
    }

    let window = min(220, d.count)
    guard window >= 60 else { return false }
    let step = max(1, window / 2)
    let chars = Array(d)
    var i = 0
    while i + window <= chars.count {
      let snippet = String(chars[i..<(i + window)])
      if o.contains(snippet) {
        return true
      }
      i += step
    }
    return false
  }

  private static func usesInputsNeededHeading(lines: [String]) -> Bool {
    for ln in lines {
      let t = ln.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if t == "# inputs needed" || t == "## inputs needed" || t == "### inputs needed" {
        return true
      }
      if t == "# inputs required" || t == "## inputs required" || t == "### inputs required" {
        return true
      }
      if t == "# needed inputs" || t == "## needed inputs" || t == "### needed inputs" {
        return true
      }
    }
    return false
  }

  private static func containsTodoPastePlaceholders(lc: String) -> Bool {
    // Flag TODO placeholders that read like "paste X", which we want converted into
    // "User Inputs to Request" bullets phrased as agent instructions.
    if lc.contains("[todo:") {
      return true
    }
    if lc.contains("todo: paste") || lc.contains("todo: attach") || lc.contains("todo: upload") {
      return true
    }
    return false
  }

  private static func normalizeHeadingAliases(in line: String) -> String {
    guard let (_, title) = parseHeading(line) else { return line }
    let t = title.lowercased()
    // Normalize common variants to the exact required heading.
    if t == "actionable task"
      || t == "actionable tasks"
      || t == "steps"
      || t == "execution steps"
      || t == "implementation plan"
      || t == "implementation task"
      || t == "implementation tasks"
      || t == "task steps"
      || t == "task plan"
    {
      return "## Implementation Steps"
    }
    return line
  }

  private static func parseHeading(_ line: String) -> (level: Int, title: String)? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("#") else { return nil }
    var level = 0
    for ch in trimmed {
      if ch == "#" {
        level += 1
      } else {
        break
      }
    }
    guard level > 0 else { return nil }
    let idx = trimmed.index(trimmed.startIndex, offsetBy: level)
    let title = trimmed[idx...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return nil }
    return (level, title)
  }

  private static func hasActionableNumberedImplementationStepsSection(lines: [String]) -> Bool {
    var inSteps = false
    var numberedCount = 0
    for ln in lines {
      if let (_, title) = parseHeading(ln) {
        // New heading starts/ends sections.
        inSteps = (title.lowercased() == "implementation steps")
        continue
      }
      if !inSteps { continue }
      if isNumberedListItem(ln) {
        numberedCount += 1
        if numberedCount >= 2 {
          return true
        }
      }
    }
    return false
  }

  private static func hasExecutionStructure(lines: [String]) -> Bool {
    let hasGoal = hasHeading(lines: lines, anyOf: [
      "goal",
      "objective",
      "goal / objective",
      "goal/objective",
    ])
    let hasScope = hasHeading(lines: lines, anyOf: [
      "scope and constraints",
      "constraints",
      "scope",
    ])
    let hasPlan = hasActionableNumberedImplementationStepsSection(lines: lines) || hasListItemsInHeading(
      lines: lines,
      heading: "review plan",
      minimumItems: 2
    )
    let hasValidation = hasHeading(lines: lines, anyOf: [
      "validation",
      "acceptance criteria",
      "acceptance checks",
      "validation / acceptance checks",
    ])
    return hasGoal && hasScope && hasPlan && hasValidation
  }

  private static func hasExplorationStructure(lines: [String]) -> Bool {
    let hasGoal = hasHeading(lines: lines, anyOf: [
      "goal",
      "goal / framing",
      "goal/framing",
      "framing",
      "question framing",
    ])
    let hasOpenQuestions = hasHeading(lines: lines, anyOf: [
      "open questions",
      "questions",
    ])
    let hasOptions = hasHeading(lines: lines, anyOf: [
      "option space",
      "tradeoffs",
      "option space / tradeoffs",
      "options",
    ])
    let hasNextSteps = hasListItemsInHeading(lines: lines, heading: "recommended next steps", minimumItems: 2)
    let hasEval = hasHeading(lines: lines, anyOf: [
      "evaluation criteria",
      "criteria",
    ])
    return hasGoal && hasOpenQuestions && hasOptions && hasNextSteps && hasEval
  }

  private static func hasTaskPlanningInstruction(lc: String) -> Bool {
    let mentionsTaskArtifact = lc.contains("task checklist")
      || lc.contains("task list")
      || lc.contains("checklist")
      || lc.contains("create/manage tasks")
      || lc.contains("manage tasks")
      || lc.contains("create tasks")
      || lc.contains("track tasks")
    let mentionsTaskAction = lc.contains("create")
      || lc.contains("maintain")
      || lc.contains("manage")
      || lc.contains("track")
      || lc.contains("keep")
    return mentionsTaskArtifact && mentionsTaskAction
  }

  private static func hasHeading(lines: [String], anyOf titles: [String]) -> Bool {
    let wanted = Set(titles.map(normalizeHeadingText))
    for line in lines {
      guard let (_, title) = parseHeading(line) else { continue }
      if wanted.contains(normalizeHeadingText(title)) {
        return true
      }
    }
    return false
  }

  private static func hasListItemsInHeading(lines: [String], heading: String, minimumItems: Int) -> Bool {
    var inTarget = false
    var itemCount = 0
    let wanted = normalizeHeadingText(heading)

    for line in lines {
      if let (_, title) = parseHeading(line) {
        inTarget = (normalizeHeadingText(title) == wanted)
        continue
      }
      guard inTarget else { continue }
      if isNumberedListItem(line) || isBulletedListItem(line) {
        itemCount += 1
        if itemCount >= minimumItems {
          return true
        }
      }
    }
    return false
  }

  private static func isBulletedListItem(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.hasPrefix("- ") || t.hasPrefix("* ")
  }

  private static func normalizeHeadingText(_ s: String) -> String {
    s
      .lowercased()
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  private static func isNumberedListItem(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return false }
    var idx = t.startIndex
    var sawDigit = false
    while idx < t.endIndex, t[idx].isNumber {
      sawDigit = true
      idx = t.index(after: idx)
    }
    guard sawDigit, idx < t.endIndex, t[idx] == "." else { return false }
    idx = t.index(after: idx)
    guard idx < t.endIndex, t[idx].isWhitespace else { return false }
    return true
  }

  private static func collapseWhitespace(_ s: String) -> String {
    s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }
}
