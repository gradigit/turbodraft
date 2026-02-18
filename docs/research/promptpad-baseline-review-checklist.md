# TurboDraft Baseline Prompt Review Checklist

Date: 2026-02-14

Use this to review a “prompt engineered” baseline as a tooling artifact (a prompt meant to drive an agent), not as prose.

## 1) Must-fail checks (reject if any are true)
- The engineered prompt includes the original draft/dictation verbatim (or large chunks of it).
- It includes rewrite meta text (system/preamble, "Output requirements", "Draft prompt to rewrite", BEGIN/END markers, etc).
- It asks the agent to access context it cannot have (logs/prior chat/files) without explicitly requesting it from the user.
- It contains contradictions (scope says “only X” but steps require “also Y”).

## 2) Fidelity check (did it preserve what you meant?)
Write 5–10 “intent atoms” from the draft, then verify each is preserved in the engineered prompt.

Examples of intent atoms:
- What feature/problem is being worked on?
- What is the observed failure/complaint?
- What is uncertain and needs a decision?
- What constraints must hold (platform, scope boundaries, non-goals)?

Mark any missing atom or any atom that got mutated into a different requirement.

## 3) Scope discipline (did it invent extra work?)
Scan for new requirements not implied by the draft.

Rule: if you’d be surprised to see it implemented, it’s scope creep and should be removed or explicitly labeled optional.

## 4) Actionability (can an agent execute this?)
- Steps are concrete and ordered (not just “consider”).
- The prompt forces explicit decisions where the draft expressed uncertainty.
- It specifies what “done” looks like (observable outcomes).

## 5) Testability (how do we verify it worked?)
- Acceptance criteria are measurable/observable.
- Each major requirement maps to at least one acceptance criterion.

## 6) Inputs and responsibility clarity
The engineered prompt should separate:

### "User Inputs to Request"
Inputs the agent must ask the user for (screenshots, logs, example files).
Each bullet should be phrased as an instruction to the agent, e.g.:
- Ask the user to paste ...
- Confirm with the user ...

### "Agent Decisions / Recommendations"
Things you want the agent to suggest or decide:
- List the decision.
- Provide 2–4 options with tradeoffs.
- State what information would change the decision.

Reject outputs that use headings like "Inputs Needed"/"Inputs Required" or that include bracketed paste TODOs like "[TODO: paste ...]".
If the prompt uses TODOs at all, they should appear only inside these sections and must make responsibility explicit (agent asks; user provides).

## 7) Concision (is it the shortest prompt that still works?)
Remove repeated phrasing and generic filler. Keep only what changes agent behavior.

## Quick score (0–2 each, target ≥ 10/12)
- Fidelity
- Scope discipline
- Actionability
- Testability
- Constraints clarity
- Concision

### Scoring anchors (to reduce subjectivity)

Fidelity:
- 0: misses or mutates key intent atoms; introduces major incorrect requirements
- 1: mostly faithful but drops 1-2 important atoms or adds minor invented scope
- 2: preserves all key atoms; no invented major scope

Scope discipline:
- 0: adds multiple surprising requirements not implied by draft
- 1: adds a few “good hygiene” items; mostly labeled optional
- 2: no meaningful scope creep; optional work clearly labeled optional

Actionability:
- 0: vague; no ordered steps; agent can’t proceed without guessing
- 1: actionable but missing ordering or decision forcing
- 2: concrete ordered steps; explicitly forces key decisions; clear “done” state

Testability:
- 0: no measurable checks; success is subjective
- 1: some criteria but incomplete mapping to requirements
- 2: measurable acceptance criteria cover all major requirements

Constraints clarity:
- 0: constraints missing or contradictory
- 1: constraints present but incomplete/implicit
- 2: constraints explicit, complete, and consistent with steps

Concision:
- 0: verbose; repeated filler; hard to scan
- 1: mostly concise with some removable repetition
- 2: dense with intent; minimal filler; easy to scan

## Judge protocol notes (if using LLM-as-judge / pairwise comparisons)
- Randomize A/B order and rerun once with swapped order; track disagreement.
- Don’t reward verbosity; longer is not automatically better.
- Treat the judge as a noisy signal; calibrate with a small human-reviewed gold set.
