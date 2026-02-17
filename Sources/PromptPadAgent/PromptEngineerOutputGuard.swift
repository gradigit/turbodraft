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

    if lc.contains("you are promptpad, a prompt engineering assistant") {
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

    if !hasActionableNumberedImplementationStepsSection(lines: lines) {
      reasons.append("missing_actionable_numbered_step_section")
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

  private static func containsDraftPrefix(draft: String, output: String) -> Bool {
    let d = collapseWhitespace(draft)
    let o = collapseWhitespace(output)
    guard d.count >= 220 else { return false }
    let idx = d.index(d.startIndex, offsetBy: 220)
    let prefix = String(d[..<idx])
    return o.contains(prefix)
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
