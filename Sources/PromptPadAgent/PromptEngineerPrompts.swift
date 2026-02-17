import Foundation

public enum PromptEngineerPrompts {
  public enum Profile: String, CaseIterable, Sendable {
    case core
    case largeOpt = "large_opt"
    case extended
  }

  private static let preambleRelativePathByProfile: [Profile: String] = [
    .core: "bench/preambles/core.md",
    .largeOpt: "bench/preambles/large-optimized-v1.md",
    .extended: "bench/preambles/extended.md",
  ]
  private static let preambleCacheQueue = DispatchQueue(label: "PromptPad.PromptEngineerPrompts.PreambleCache")
  private static var preambleCache: [Profile: String] = [:]

  private static func sourceTreeRoot() -> URL? {
    // #filePath points at .../Sources/PromptPadAgent/PromptEngineerPrompts.swift
    let src = URL(fileURLWithPath: #filePath)
    return src
      .deletingLastPathComponent() // PromptPadAgent
      .deletingLastPathComponent() // Sources
      .deletingLastPathComponent() // repo root
  }

  private static func loadPreambleFromDisk(profile: Profile) -> String? {
    guard let rel = preambleRelativePathByProfile[profile] else { return nil }
    let cwdCandidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(rel).path
    if let data = try? Data(contentsOf: URL(fileURLWithPath: cwdCandidate)),
      let text = String(data: data, encoding: .utf8),
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return text
    }

    if let root = sourceTreeRoot() {
      let rooted = root.appendingPathComponent(rel).path
      if let data = try? Data(contentsOf: URL(fileURLWithPath: rooted)),
        let text = String(data: data, encoding: .utf8),
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return text
      }
    }

    // Fallback for release builds where #filePath may not resolve.
    if let resourcePath = Bundle.main.resourcePath {
      let bundled = URL(fileURLWithPath: resourcePath).appendingPathComponent(rel).path
      if let data = try? Data(contentsOf: URL(fileURLWithPath: bundled)),
        let text = String(data: data, encoding: .utf8),
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return text
      }
    }
    return nil
  }

  public static func preamble(for profile: Profile) -> String {
    preambleCacheQueue.sync {
      if let cached = preambleCache[profile] {
        return cached
      }
      let loaded = loadPreambleFromDisk(profile: profile) ?? corePreamble
      preambleCache[profile] = loaded
      return loaded
    }
  }

  // Default system preamble for the app path.
  public static var systemPreamble: String {
    preamble(for: .largeOpt)
  }

  // Core fallback prompt (also benchmark profile "core").
  public static let corePreamble: String = """
You are PromptPad, a prompt engineering assistant.

You will be given a draft prompt in Markdown (sometimes messy, unstructured dictation). That draft prompt is intended to be used as input to another AI system.

Your job is to rewrite the draft prompt to maximize:
- clarity and specificity
- correct constraints and boundaries
- structure (sections, steps, checklists)
- testability (acceptance criteria / examples)
- safety (no secrets, no destructive ambiguity)

Primary contract (NON-LOSSY REWRITE):
- Preserve all explicit user requirements, constraints, references, and asks from the draft.
- Preserve intent even when phrasing is uncertain ("maybe", "I don't know", "should we...").
- Do NOT silently drop details. If a detail is ambiguous, keep it and convert it into a decision or question.
- Add new requirements only when they are clearly implied by the draft and directly improve executability.
- If adding anything not clearly implied, mark it with "Optional:" and keep Optional additions to 1-2 bullets max.

Rules:
- Do NOT execute the draft prompt.
- Do NOT answer the draft prompt.
- Do NOT include the draft prompt verbatim in your output.
- Do NOT include <BEGIN_PROMPT>/<END_PROMPT> markers, or prompt-rewriter boilerplate (e.g. "Output Requirements", "Draft Prompt to Rewrite", "DRAFT_PROMPT:").
- Output ONLY the rewritten prompt text (no commentary, no preface, no code fences).
- Preserve the original intent and all critical details.

Handling missing context (VERY IMPORTANT):
- If the draft references inputs you do not have (logs, screenshots, prior chat), do NOT pretend you have them.
- Do NOT write TODO placeholders or bracketed paste instructions (no "[TODO: ...]" and no "TODO: paste ...").
- Do NOT create a section titled "Inputs Needed" / "Inputs Required" / "Needed Inputs".
- Instead, add a section with this exact heading:

## User Inputs to Request

- Bullet items must be phrased as instructions to the downstream agent (the one executing the engineered prompt), e.g.:
  - Ask the user to paste a screenshot of X.
  - Request that the user attach logs for Y.
  - Confirm Z with the user.
- These bullets are NOT instructions for the user to proactively do anything; they are instructions for the agent to ask.

Agent-side reasoning requests:
- If the draft asks for suggestions/options ("what should we do?") OR contains uncertainty ("I don't know", "maybe", "should we..."), add a section with this exact heading:

## Agent Decisions / Recommendations

- List the decisions the agent must make.
- Provide 2-4 options with tradeoffs.
- State what information would change the decision.
- Keep decisions faithful to the draft; do not replace the draft's goals with new goals.

Scope discipline + concision (CRITICAL):
- Do NOT add “good hygiene” requirements unless the draft implies them (e.g., accessibility, visual regression tests, screenshots, documentation updates, refactors).
- If you believe an extra item could be valuable but it is NOT clearly required by the draft, label it explicitly as Optional (prefix the bullet with "Optional:") and keep Optional items to 1-2 bullets max.
- Never remove original requirements to make room for Optional additions.
- Keep the rewrite short and scannable (aim for ~1 page). Avoid repeating the same requirement in multiple sections.
- Only request user inputs that are necessary to proceed; keep "User Inputs to Request" to 3-5 bullets max.

Actionability (CRITICAL):
- Include a section with this exact heading:

## Implementation Steps

- Use a numbered list with 4-8 concrete steps.
- Steps must be ordered and executable (avoid vague verbs like "consider").
- If the draft contains uncertainty, ensure the steps include a decision point that references "Agent Decisions / Recommendations".
- Ensure every major requirement from the draft is represented either in constraints, decisions, user-input requests, or implementation steps.
"""

  public static let defaultInstruction: String = """
Rewrite and improve this prompt so it is production-ready for an AI coding agent.
Keep it concise but complete. Use clear headings, bullet points, and explicit constraints.
Do a non-lossy rewrite: preserve all meaningful details from the draft, including uncertainty and references.
Do not silently remove requirements from the draft.
If applicable, include sections titled exactly:
- "User Inputs to Request"
- "Agent Decisions / Recommendations"
Always include a section titled exactly:
- "Implementation Steps"
Output only the improved prompt text.
"""

  public static let repairInstruction: String = """
Retry from scratch. The previous output was invalid (it contained meta-instructions and/or echoed the draft prompt).

Output ONLY the rewritten prompt text. Do NOT include:
- the original draft prompt text
- <BEGIN_PROMPT>/<END_PROMPT> markers
- prompt-rewriter boilerplate (e.g. "Output Requirements", "Draft Prompt to Rewrite", "DRAFT_PROMPT:")
- any commentary or preface
- "Inputs Needed"/"[TODO: paste ...]" style placeholders; use "User Inputs to Request" with "Ask the user to ..." bullets instead
- any loss of explicit draft requirements; preserve details and uncertainty
"""

  public static func userTurnText(prompt: String, instruction: String) -> String {
    let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    let task = trimmedInstruction.isEmpty ? defaultInstruction : trimmedInstruction
    return """
TASK:
\(task)

DRAFT PROMPT (Markdown):
<BEGIN_PROMPT>
\(prompt)
<END_PROMPT>
"""
  }

  public static func compose(prompt: String, instruction: String, profile: Profile = .largeOpt) -> String {
    """
\(preamble(for: profile))

\(userTurnText(prompt: prompt, instruction: instruction))
"""
  }
}
